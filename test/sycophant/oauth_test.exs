defmodule Sycophant.OAuthTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Assent.HTTPAdapter.HTTPResponse
  alias Assent.JWTAdapter.AssentJWT
  alias Sycophant.Error.Invalid.OAuthFailed
  alias Sycophant.OAuth
  alias Sycophant.OAuth.Credential
  alias Sycophant.OAuth.Session

  @config %{
    authorize_url: "https://auth.example.com/authorize",
    token_url: "https://auth.example.com/token",
    issuer: "https://auth.example.com",
    redirect_uri: "http://127.0.0.1:1455/auth/callback",
    scopes: ["openid", "email", "offline_access"],
    client_id: "base_client",
    authorization_params: [resource: "https://api.example.com/v1", login_hint: "a@b.c"],
    token_params: [resource: "https://api.example.com/v1"],
    client_id_from_callback: false,
    revoke_url: "https://auth.example.com/revoke"
  }

  describe "authorize_url/2" do
    test "builds a PKCE + OIDC authorize URL bound to the returned session" do
      assert {:ok, url, %Session{} = session} =
               OAuth.authorize_url(@config, expected_client_id: "oaiapp_1")

      uri = URI.parse(url)
      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == @config.authorize_url
      query = URI.decode_query(uri.query)

      assert query["response_type"] == "code"
      assert query["client_id"] == "base_client"
      assert query["redirect_uri"] == @config.redirect_uri
      assert query["scope"] == "openid email offline_access"
      assert query["state"] == session.state
      assert query["nonce"] == session.nonce
      assert query["code_challenge_method"] == "S256"

      assert query["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, session.code_verifier), padding: false)

      assert query["resource"] == "https://api.example.com/v1"
      assert query["login_hint"] == "a@b.c"
      assert session.client_id == "oaiapp_1"
      assert session.redirect_uri == @config.redirect_uri
    end

    test "leaves the expected client id empty on first registration" do
      assert {:ok, _url, %Session{client_id: nil}} = OAuth.authorize_url(@config)
    end
  end

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    other_key = :public_key.generate_key({:rsa, 2048, 65_537})
    %{key: key, other_key: other_key}
  end

  setup %{key: key} do
    session = %Session{
      state: "state-123",
      nonce: "nonce-123",
      code_verifier: "verifier-123",
      redirect_uri: @config.redirect_uri,
      client_id: nil,
      created_at: DateTime.utc_now()
    }

    %{session: session, id_token: sign(key, claims())}
  end

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => @config.issuer,
        "sub" => "user-1",
        "aud" => "base_client",
        "exp" => now + 600,
        "iat" => now,
        "nonce" => "nonce-123",
        "email" => "user@example.com"
      },
      overrides
    )
  end

  defp sign(key, claims) do
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    {:ok, token} = AssentJWT.sign(claims, "RS256", pem, json_library: JSON)
    token
  end

  defp jwk(key) do
    {:RSAPrivateKey, _version, n, e, _d, _p, _q, _dp, _dq, _qi, _other} = key
    encode = &Base.url_encode64(:binary.encode_unsigned(&1), padding: false)
    %{"kty" => "RSA", "alg" => "RS256", "use" => "sig", "n" => encode.(n), "e" => encode.(e)}
  end

  defp json(status, body) do
    {:ok,
     %HTTPResponse{
       status: status,
       headers: [{"content-type", "application/json"}],
       body: JSON.encode!(body)
     }}
  end

  defp token_body(id_token) do
    %{
      "access_token" => "access-1",
      "refresh_token" => "refresh-1",
      "id_token" => id_token,
      "scope" => "openid email offline_access",
      "expires_in" => 3600,
      "token_type" => "Bearer"
    }
  end

  defp stub_provider(key, token_response, issuer \\ @config.issuer) do
    test = self()

    stub(Sycophant.OAuth.HTTPAdapter, :request, fn
      :post, "https://auth.example.com/token", body, _headers, _opts ->
        send(test, {:token_request, URI.decode_query(body)})
        token_response

      :get, "https://auth.example.com/.well-known/openid-configuration", nil, _headers, _opts ->
        json(200, %{
          "issuer" => issuer,
          "jwks_uri" => "https://auth.example.com/jwks",
          "revocation_endpoint" => "https://auth.example.com/revoke"
        })

      :get, "https://auth.example.com/jwks", nil, _headers, _opts ->
        json(200, %{"keys" => [jwk(key)]})
    end)
  end

  describe "exchange/3" do
    test "exchanges the code and returns a credential from validated ID token claims", ctx do
      stub_provider(ctx.key, json(200, token_body(ctx.id_token)))
      callback = %{"code" => "code-1", "state" => "state-123"}

      assert {:ok, %Credential{} = cred} = OAuth.exchange(@config, ctx.session, callback)

      assert cred.access_token == "access-1"
      assert cred.refresh_token == "refresh-1"
      assert cred.id_token == ctx.id_token
      assert cred.token_type == "Bearer"
      assert cred.subject == "user-1"
      assert cred.email == "user@example.com"
      assert cred.issuer == @config.issuer
      assert cred.client_id == "base_client"
      assert cred.scopes == ["openid", "email", "offline_access"]
      assert_in_delta DateTime.diff(cred.expires_at, cred.obtained_at), 3600, 1

      assert_received {:token_request, form}

      assert form == %{
               "grant_type" => "authorization_code",
               "code" => "code-1",
               "code_verifier" => "verifier-123",
               "redirect_uri" => @config.redirect_uri,
               "client_id" => "base_client",
               "resource" => "https://api.example.com/v1"
             }
    end

    test "rejects bad callbacks without issuing a token request", ctx do
      reject(Sycophant.OAuth.HTTPAdapter, :request, 5)
      from_callback = %{@config | client_id_from_callback: true}
      reauth = %{ctx.session | client_id: "a"}
      ok = %{"code" => "code-1", "state" => "state-123"}

      assert {:error, %OAuthFailed{code: "access_denied"}} =
               OAuth.exchange(@config, ctx.session, %{"error" => "access_denied"})

      assert {:error, %OAuthFailed{}} =
               OAuth.exchange(@config, ctx.session, %{ok | "state" => "state-999"})

      assert {:error, %OAuthFailed{}} =
               OAuth.exchange(@config, ctx.session, Map.delete(ok, "state"))

      assert {:error, %OAuthFailed{}} =
               OAuth.exchange(@config, ctx.session, Map.delete(ok, "code"))

      assert {:error, %OAuthFailed{}} = OAuth.exchange(from_callback, ctx.session, ok)

      assert {:error, %OAuthFailed{}} =
               OAuth.exchange(from_callback, ctx.session, Map.put(ok, "client_id", ""))

      assert {:error, %OAuthFailed{}} =
               OAuth.exchange(from_callback, reauth, Map.put(ok, "client_id", "b"))
    end

    test "resolves the client id used for the token request and ID token audience", ctx do
      ok = %{"code" => "code-1", "state" => "state-123"}
      from_callback = %{@config | client_id_from_callback: true}
      reauth = %{ctx.session | client_id: "a"}

      cases = [
        {@config, ctx.session, Map.put(ok, "client_id", "ignored"), "base_client"},
        {from_callback, ctx.session, Map.put(ok, "client_id", "issued"), "issued"},
        {from_callback, reauth, ok, "a"},
        {from_callback, reauth, Map.put(ok, "client_id", "a"), "a"}
      ]

      for {config, session, callback, expected} <- cases do
        id_token = sign(ctx.key, claims(%{"aud" => expected}))
        stub_provider(ctx.key, json(200, token_body(id_token)))

        assert {:ok, %Credential{client_id: ^expected}} =
                 OAuth.exchange(config, session, callback)

        assert_received {:token_request, %{"client_id" => ^expected}}
      end
    end

    test "rejects ID tokens that fail validation", ctx do
      callback = %{"code" => "code-1", "state" => "state-123"}
      now = System.system_time(:second)

      bad_tokens = [
        sign(ctx.other_key, claims()),
        sign(ctx.key, claims(%{"iss" => "https://evil.example.com"})),
        sign(ctx.key, claims(%{"aud" => "someone_else"})),
        sign(ctx.key, claims(%{"exp" => now - 10, "iat" => now - 700})),
        sign(ctx.key, claims(%{"nonce" => "other-nonce"})),
        sign(ctx.key, Map.delete(claims(), "nonce"))
      ]

      for id_token <- bad_tokens do
        stub_provider(ctx.key, json(200, token_body(id_token)))
        assert {:error, %OAuthFailed{}} = OAuth.exchange(@config, ctx.session, callback)
      end
    end

    test "rejects an issuer that differs from the configured one even when discovery agrees",
         ctx do
      id_token = sign(ctx.key, claims(%{"iss" => "https://evil.example.com"}))
      stub_provider(ctx.key, json(200, token_body(id_token)), "https://evil.example.com")
      callback = %{"code" => "code-1", "state" => "state-123"}

      assert {:error, %OAuthFailed{}} = OAuth.exchange(@config, ctx.session, callback)
    end

    test "rejects token responses missing required fields without leaking tokens", ctx do
      callback = %{"code" => "code-1", "state" => "state-123"}

      for field <- ["id_token", "refresh_token", "expires_in", "token_type"] do
        stub_provider(ctx.key, json(200, Map.delete(token_body(ctx.id_token), field)))

        assert {:error, %OAuthFailed{} = error} =
                 OAuth.exchange(@config, ctx.session, callback)

        refute inspect(error) =~ "access-1"
        refute Exception.message(error) =~ "access-1"
      end
    end

    test "maps an OAuth error body from the token endpoint to its code", ctx do
      stub_provider(
        ctx.key,
        json(400, %{"error" => "invalid_grant", "error_description" => "code expired"})
      )

      callback = %{"code" => "code-1", "state" => "state-123"}

      assert {:error, %OAuthFailed{code: "invalid_grant"}} =
               OAuth.exchange(@config, ctx.session, callback)
    end
  end

  defp credential(id_token) do
    now = DateTime.utc_now()

    %Credential{
      access_token: "access-0",
      refresh_token: "refresh-0",
      id_token: id_token,
      token_type: "Bearer",
      client_id: "oaiapp_1",
      issuer: @config.issuer,
      subject: "user-1",
      email: "user@example.com",
      scopes: ["openid"],
      expires_at: now,
      obtained_at: DateTime.add(now, -3600)
    }
  end

  describe "refresh/2" do
    test "rotates tokens and preserves identity when no ID token is returned", ctx do
      body =
        ctx.id_token
        |> token_body()
        |> Map.drop(["id_token", "scope"])
        |> Map.merge(%{"access_token" => "access-2", "refresh_token" => "refresh-2"})

      stub_provider(ctx.key, json(200, body))
      input = credential(ctx.id_token)

      assert {:ok, %Credential{} = cred} = OAuth.refresh(@config, input)

      assert_received {:token_request, form}

      assert form == %{
               "grant_type" => "refresh_token",
               "refresh_token" => "refresh-0",
               "client_id" => "oaiapp_1",
               "resource" => "https://api.example.com/v1"
             }

      assert cred.access_token == "access-2"
      assert cred.refresh_token == "refresh-2"
      assert DateTime.after?(cred.expires_at, input.expires_at)

      assert Map.take(cred, [:client_id, :issuer, :subject, :email, :id_token, :scopes]) ==
               Map.take(input, [:client_id, :issuer, :subject, :email, :id_token, :scopes])
    end

    test "returns the OAuth error code for a rejected refresh token", ctx do
      stub_provider(ctx.key, json(400, %{"error" => "invalid_grant"}))

      assert {:error, %OAuthFailed{code: "invalid_grant"} = error} =
               OAuth.refresh(@config, credential(ctx.id_token))

      refute inspect(error) =~ "refresh-0"

      stub(Sycophant.OAuth.HTTPAdapter, :request, fn _m, _u, _b, _h, _o ->
        {:error, :econnrefused}
      end)

      assert {:error, %OAuthFailed{code: nil, reason: reason}} =
               OAuth.refresh(@config, credential(ctx.id_token))

      assert reason =~ "unreachable"
    end
  end

  describe "revoke/2" do
    test "posts the refresh token to the revocation URL", ctx do
      test = self()

      expect(Sycophant.OAuth.HTTPAdapter, :request, fn
        :post, "https://auth.example.com/revoke", body, headers, _opts ->
          send(test, {:revoke, URI.decode_query(body), headers})
          {:ok, %HTTPResponse{status: 200, body: ""}}
      end)

      assert :ok = OAuth.revoke(@config, credential(ctx.id_token))
      assert_received {:revoke, form, headers}

      assert form == %{
               "token" => "refresh-0",
               "token_type_hint" => "refresh_token",
               "client_id" => "oaiapp_1"
             }

      assert {"content-type", "application/x-www-form-urlencoded"} in headers
    end

    test "fails on a non-2xx response or a missing revocation URL", ctx do
      stub(Sycophant.OAuth.HTTPAdapter, :request, fn :post, _url, _body, _headers, _opts ->
        json(400, %{"error" => "unsupported_token_type"})
      end)

      assert {:error, %OAuthFailed{code: "unsupported_token_type"}} =
               OAuth.revoke(@config, credential(ctx.id_token))

      reject(Sycophant.OAuth.HTTPAdapter, :request, 5)

      assert {:error, %OAuthFailed{}} =
               OAuth.revoke(%{@config | revoke_url: nil}, credential(ctx.id_token))
    end
  end
end
