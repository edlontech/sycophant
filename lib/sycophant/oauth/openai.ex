defmodule Sycophant.OAuth.OpenAI do
  @moduledoc """
  Sign in with ChatGPT for locally hosted applications.

  The application owns browser navigation, callbacks, secure persistence, and
  refresh scheduling. See the [OpenAI ChatGPT Plan guide](openai-chatgpt.html).
  """

  alias Sycophant.Error.Invalid.InvalidParams
  alias Sycophant.Error.Invalid.OAuthFailed
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.OAuth
  alias Sycophant.OAuth.Credential
  alias Sycophant.OAuth.Session

  @authorize_url "https://auth.openai.com/api/accounts/authorize"
  @token_url "https://auth.openai.com/api/accounts/oauth/token"
  @issuer "https://auth.openai.com"
  @resource "https://api.openai.com/v1"
  @scopes ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct)
  @registration_client_id "dynamic_agent_client"
  @revoke_url "https://auth.openai.com/api/accounts/oauth/revoke"

  @doc """
  Builds an authorization URL and pending session for registration or re-login.

  Requires `:host_id` (an installation's stable `urn:uuid:...`) and
  `:redirect_uri` starting with `http://127.0.0.1:`. First registration requires
  `:agent_name`. Re-login takes the issued `:client_id`, with optional
  `:id_token_hint` and `:login_hint`, instead of an agent name.
  """
  @spec authorize_url(keyword()) :: {:ok, String.t(), Session.t()} | {:error, Splode.Error.t()}
  def authorize_url(opts) do
    name_schema = Zoi.min(Zoi.string(), 1)
    name_schema = if opts[:client_id], do: Zoi.optional(name_schema), else: name_schema

    schema =
      Zoi.map(%{
        host_id: Zoi.regex(Zoi.string(), ~r/^urn:uuid:[0-9a-f-]{36}$/i),
        redirect_uri: Zoi.regex(Zoi.string(), ~r{^http://127\.0\.0\.1:\d+/}),
        agent_name: name_schema,
        client_id: Zoi.optional(Zoi.min(Zoi.string(), 1)),
        id_token_hint: Zoi.optional(Zoi.string()),
        login_hint: Zoi.optional(Zoi.string())
      })

    case Zoi.parse(schema, Map.new(opts)) do
      {:ok, validated} ->
        opts = Map.to_list(validated)
        OAuth.authorize_url(config(opts), expected_client_id: opts[:client_id])

      {:error, errors} ->
        {:error, InvalidParams.exception(errors: errors)}
    end
  end

  @doc "Exchanges callback params, requiring an issued oaiapp_ client ID on first login."
  @spec exchange(Session.t(), map()) :: {:ok, Credential.t()} | {:error, Splode.Error.t()}
  def exchange(%Session{} = session, params) do
    with {:ok, credential} <-
           OAuth.exchange(config(redirect_uri: session.redirect_uri), session, params) do
      if is_nil(session.client_id) and not String.starts_with?(credential.client_id, "oaiapp_") do
        {:error,
         OAuthFailed.exception(reason: "registration did not return an oaiapp_ client id")}
      else
        {:ok, credential}
      end
    end
  end

  @doc "Refreshes a credential. The application must securely persist the rotated tokens."
  @spec refresh(Credential.t()) :: {:ok, Credential.t()} | {:error, Splode.Error.t()}
  def refresh(%Credential{} = credential), do: OAuth.refresh(config([]), credential)

  @doc "Revokes the refresh token at OpenAI's static endpoint. Revocation is best effort."
  @spec revoke(Credential.t()) :: :ok | {:error, Splode.Error.t()}
  def revoke(%Credential{} = credential), do: OAuth.revoke(config([]), credential)

  @doc "Whether the credential grants use of the user's ChatGPT plan."
  @spec plan_usage_enabled?(Credential.t()) :: boolean()
  def plan_usage_enabled?(%Credential{scopes: scopes}),
    do: "chatgpt.tokens.use.direct" in scopes

  @doc "Lists account-visible models using a credential or an access token."
  @spec list_models(Credential.t() | String.t()) ::
          {:ok, [%{slug: String.t(), display_name: String.t()}]} | {:error, Splode.Error.t()}
  def list_models(%Credential{access_token: token}), do: list_models(token)

  def list_models(token) when is_binary(token) do
    {:ok, tesla_config} = Sycophant.Config.tesla()

    client =
      Tesla.client(
        [
          {Tesla.Middleware.BaseUrl, @resource},
          Tesla.Middleware.JSON,
          {Tesla.Middleware.Headers, [{"authorization", "Bearer #{token}"}]}
        ],
        tesla_config.adapter
      )

    case Tesla.get(client, "/models") do
      {:ok, %Tesla.Env{status: status, body: %{"models" => models}}} when status in 200..299 ->
        visible =
          for %{"slug" => slug, "display_name" => name, "visibility" => "list"} <- models,
              do: %{slug: slug, display_name: name}

        {:ok, visible}

      {:ok, %Tesla.Env{status: status}} when status in 200..299 ->
        {:error, ServerError.exception(body: "Malformed OpenAI model listing response")}

      {:ok, %Tesla.Env{} = env} ->
        Sycophant.Transport.map_error(env)

      {:error, reason} ->
        {:error, ServerError.exception(body: inspect(reason))}
    end
  end

  defp authorization_params(opts) do
    hints =
      if opts[:client_id] do
        Keyword.take(opts, [:id_token_hint, :login_hint])
      else
        [agent_name_hint: opts[:agent_name]]
      end

    [resource: @resource, ext_agent_host_id: opts[:host_id]] ++ hints
  end

  defp config(opts) do
    %{
      authorize_url: @authorize_url,
      token_url: @token_url,
      issuer: @issuer,
      redirect_uri: opts[:redirect_uri],
      scopes: @scopes,
      client_id: opts[:client_id] || @registration_client_id,
      authorization_params: authorization_params(opts),
      token_params: [resource: @resource],
      client_id_from_callback: true,
      revoke_url: @revoke_url
    }
  end
end
