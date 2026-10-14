defmodule Sycophant.OAuth.OpenAITest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.OAuth.OpenAI

  @host_id "urn:uuid:12345678-1234-1234-1234-123456789abc"
  @redirect_uri "http://127.0.0.1:1455/auth/callback"

  test "rejects redirect userinfo masquerading as a loopback port" do
    assert {:error, %Sycophant.Error.Invalid.InvalidParams{}} =
             OpenAI.authorize_url(
               host_id: @host_id,
               redirect_uri: "http://127.0.0.1:@evil.com/cb",
               agent_name: "Yach"
             )
  end

  test "first registration binds the installation and requests plan usage with PKCE" do
    assert {:ok, url, session} =
             OpenAI.authorize_url(
               host_id: @host_id,
               redirect_uri: @redirect_uri,
               agent_name: "Yach"
             )

    uri = URI.parse(url)

    assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
             "https://auth.openai.com/api/accounts/authorize"

    query = URI.decode_query(uri.query)
    assert query["client_id"] == "dynamic_agent_client"
    assert query["agent_name_hint"] == "Yach"
    assert query["ext_agent_host_id"] == @host_id
    assert query["resource"] == "https://api.openai.com/v1"

    assert query["scope"] ==
             "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    assert query["code_challenge_method"] == "S256"
    refute Map.has_key?(query, "id_token_hint")
    refute Map.has_key?(query, "login_hint")
    assert session.client_id == nil
    assert session.redirect_uri == @redirect_uri
  end

  test "re-authorization uses the issued client id and hints, not a new registration" do
    assert {:ok, url, session} =
             OpenAI.authorize_url(
               host_id: @host_id,
               redirect_uri: @redirect_uri,
               client_id: "oaiapp_x",
               id_token_hint: "jwt",
               login_hint: "u@example.com",
               agent_name: "Ignored"
             )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == "oaiapp_x"
    assert query["id_token_hint"] == "jwt"
    assert query["login_hint"] == "u@example.com"
    refute Map.has_key?(query, "agent_name_hint")
    assert session.client_id == "oaiapp_x"
  end

  test "rejects invalid installation identity, redirect, and missing registration name" do
    valid = [host_id: @host_id, redirect_uri: @redirect_uri, agent_name: "Yach"]

    for opts <- [
          Keyword.delete(valid, :host_id),
          Keyword.put(valid, :host_id, "bad"),
          Keyword.put(valid, :redirect_uri, "http://localhost:1455/auth/callback"),
          Keyword.delete(valid, :redirect_uri),
          Keyword.delete(valid, :agent_name)
        ] do
      assert {:error, %Sycophant.Error.Invalid.InvalidParams{}} = OpenAI.authorize_url(opts)
    end
  end

  test "first exchange accepts only issued application client ids and preserves the credential" do
    {:ok, _url, session} =
      OpenAI.authorize_url(host_id: @host_id, redirect_uri: @redirect_uri, agent_name: "Yach")

    params = %{"code" => "code", "state" => "state"}

    for id <- ["dynamic_agent_client", "oaiapp_x"] do
      credential = %Sycophant.OAuth.Credential{
        access_token: "access",
        refresh_token: "refresh",
        id_token: "jwt",
        token_type: "Bearer",
        client_id: id,
        issuer: "https://auth.openai.com",
        subject: "user",
        expires_at: DateTime.utc_now(),
        obtained_at: DateTime.utc_now()
      }

      expect(Sycophant.OAuth, :exchange, fn config, ^session, ^params ->
        assert config.redirect_uri == @redirect_uri
        assert config.client_id_from_callback
        assert config.token_params == [resource: "https://api.openai.com/v1"]
        {:ok, credential}
      end)

      case id do
        "oaiapp_x" ->
          assert OpenAI.exchange(session, params) == {:ok, credential}

        _ ->
          assert {:error, %Sycophant.Error.Invalid.OAuthFailed{}} =
                   OpenAI.exchange(session, params)
      end
    end
  end

  test "plan usage requires the granted direct-use scope" do
    credential = struct(Sycophant.OAuth.Credential, scopes: ["openid"])
    refute OpenAI.plan_usage_enabled?(credential)
    assert OpenAI.plan_usage_enabled?(%{credential | scopes: ["chatgpt.tokens.use.direct"]})
  end

  test "refresh and revoke use the OpenAI resource and static revocation endpoint" do
    credential = struct(Sycophant.OAuth.Credential, client_id: "oaiapp_x")

    expect(Sycophant.OAuth, :refresh, fn config, ^credential ->
      assert config.token_params == [resource: "https://api.openai.com/v1"]
      assert config.token_url == "https://auth.openai.com/api/accounts/oauth/token"
      assert config.issuer == "https://auth.openai.com"
      {:ok, credential}
    end)

    assert OpenAI.refresh(credential) == {:ok, credential}

    expect(Sycophant.OAuth, :revoke, fn config, ^credential ->
      assert config.token_params == [resource: "https://api.openai.com/v1"]
      assert config.revoke_url == "https://auth.openai.com/api/accounts/oauth/revoke"
      :ok
    end)

    assert OpenAI.revoke(credential) == :ok
  end

  test "model listing preserves visible model order and authenticates with a Bearer token" do
    for input <- ["access", struct(Sycophant.OAuth.Credential, access_token: "access")] do
      expect(Tesla, :get, fn client, "/models" ->
        {_, headers} =
          Enum.find_value(client.pre, fn
            {Tesla.Middleware.Headers, :call, [headers]} -> {:headers, headers}
            _ -> nil
          end)

        assert {"authorization", "Bearer access"} in headers

        {:ok,
         %Tesla.Env{
           status: 200,
           body: %{
             "models" => [
               %{"slug" => "a", "display_name" => "A", "visibility" => "list"},
               %{"slug" => "b", "display_name" => "B", "visibility" => "hidden"},
               %{"slug" => "c", "display_name" => "C", "visibility" => "list"}
             ]
           }
         }}
      end)

      assert OpenAI.list_models(input) ==
               {:ok, [%{slug: "a", display_name: "A"}, %{slug: "c", display_name: "C"}]}
    end
  end

  test "model listing returns actionable authentication, subscription, and network errors" do
    expect(Tesla, :get, fn _, "/models" -> {:ok, %Tesla.Env{status: 401, body: %{}}} end)

    assert {:error, %Sycophant.Error.Provider.AuthenticationFailed{}} =
             OpenAI.list_models("access")

    expect(Tesla, :get, fn _, "/models" ->
      {:ok,
       %Tesla.Env{
         status: 403,
         body: %{"error" => %{"code" => "subscription_sharing_user_not_eligible"}}
       }}
    end)

    assert {:error,
            %Sycophant.Error.Provider.SubscriptionError{
              code: "subscription_sharing_user_not_eligible"
            }} = OpenAI.list_models("access")

    expect(Tesla, :get, fn _, "/models" -> {:error, :closed} end)
    assert {:error, %Sycophant.Error.Provider.ServerError{}} = OpenAI.list_models("access")
    expect(Tesla, :get, fn _, "/models" -> {:ok, %Tesla.Env{status: 200, body: %{}}} end)
    assert {:error, %Sycophant.Error.Provider.ServerError{}} = OpenAI.list_models("access")
  end
end
