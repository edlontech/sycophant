defmodule Sycophant.OAuth do
  @moduledoc """
  Provider-neutral OAuth 2.0 authorization code flow with PKCE and OpenID Connect
  ID token validation, built on Assent.

  Provider presets supply the endpoints, scopes, and extra parameters as a
  `t:config/0` map. The caller holds the `Sycophant.OAuth.Session` between
  `authorize_url/2` and `exchange/3`, and persists the resulting
  `Sycophant.OAuth.Credential`.
  """

  alias Assent.HTTPAdapter.HTTPResponse
  alias Assent.InvalidResponseError
  alias Assent.RequestError
  alias Assent.Strategy.OAuth2
  alias Assent.Strategy.OIDC
  alias Assent.UnexpectedResponseError
  alias Sycophant.Error.Invalid.OAuthFailed
  alias Sycophant.OAuth.Credential
  alias Sycophant.OAuth.Session

  @type config :: %{
          authorize_url: String.t(),
          token_url: String.t(),
          issuer: String.t(),
          redirect_uri: String.t(),
          scopes: [String.t()],
          client_id: String.t(),
          authorization_params: keyword(),
          token_params: keyword(),
          client_id_from_callback: boolean(),
          revoke_url: String.t() | nil
        }

  @doc """
  Builds the authorization URL and the session to hold until the callback.

  `opts[:expected_client_id]` is the issued client ID expected back in the
  callback on re-authorization; it is stored as `Session.client_id`.
  """
  @spec authorize_url(config(), keyword()) ::
          {:ok, String.t(), Session.t()} | {:error, Splode.Error.t()}
  def authorize_url(config, opts \\ []) do
    nonce = random_token()

    assent =
      config
      |> assent_config(config.client_id)
      |> Keyword.update!(:authorization_params, &Keyword.put(&1, :nonce, nonce))

    case OAuth2.authorize_url(assent) do
      {:ok, %{url: url, session_params: params}} ->
        {:ok, url,
         %Session{
           state: params.state,
           nonce: nonce,
           code_verifier: params.code_verifier,
           redirect_uri: config.redirect_uri,
           client_id: opts[:expected_client_id],
           created_at: DateTime.utc_now()
         }}

      {:error, error} ->
        {:error, wrap_error(error)}
    end
  end

  @doc """
  Exchanges the authorization callback params for a validated credential.

  Rejects callback errors, state mismatches, missing codes, and client ID
  mismatches before any token request. The ID token is validated against the
  issuer's JWKS, issuer, audience (the resolved client ID), expiry, and nonce.
  """
  @spec exchange(config(), Session.t(), %{String.t() => String.t()}) ::
          {:ok, Credential.t()} | {:error, Splode.Error.t()}
  def exchange(config, %Session{} = session, params) do
    with :ok <- check_callback_error(params),
         :ok <- verify_state(session.state, params["state"]),
         {:ok, code} <- fetch_code(params),
         {:ok, client_id} <- resolve_client_id(config, session, params) do
      assent = assent_config(config, client_id)

      grant_params =
        [code: code, redirect_uri: session.redirect_uri, code_verifier: session.code_verifier] ++
          config.token_params

      grant_and_validate(config, session, assent, client_id, grant_params)
    end
  end

  defp check_callback_error(%{"error" => code} = params) do
    {:error, OAuthFailed.exception(reason: params["error_description"] || code, code: code)}
  end

  defp check_callback_error(_params), do: :ok

  defp verify_state(expected, actual) when is_binary(actual) do
    if Assent.constant_time_compare(expected, actual),
      do: :ok,
      else: {:error, OAuthFailed.exception(reason: "callback state does not match the session")}
  end

  defp verify_state(_expected, _actual),
    do: {:error, OAuthFailed.exception(reason: "callback is missing the state parameter")}

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}

  defp fetch_code(_params),
    do: {:error, OAuthFailed.exception(reason: "callback is missing the authorization code")}

  defp resolve_client_id(%{client_id_from_callback: false} = config, _session, _params),
    do: {:ok, config.client_id}

  defp resolve_client_id(_config, %Session{client_id: expected}, params) do
    callback_id = if params["client_id"] in [nil, ""], do: nil, else: params["client_id"]

    case {expected, callback_id} do
      {nil, nil} ->
        {:error, OAuthFailed.exception(reason: "registration did not return an issued client id")}

      {nil, issued} ->
        {:ok, issued}

      {id, nil} ->
        {:ok, id}

      {id, id} ->
        {:ok, id}

      {_id, _other} ->
        {:error,
         OAuthFailed.exception(reason: "callback client id does not match the pending request")}
    end
  end

  defp grant_and_validate(config, session, assent, client_id, grant_params) do
    with {:ok, token} <- OAuth2.grant_access_token(assent, "authorization_code", grant_params),
         {:ok, id_token} <- fetch_token(token, "id_token"),
         {:ok, refresh_token} <- fetch_token(token, "refresh_token"),
         {:ok, jwt} <-
           OIDC.validate_id_token(assent ++ [session_params: %{nonce: session.nonce}], id_token),
         :ok <- verify_issuer(jwt.claims, config.issuer) do
      build_credential(token, %{
        refresh_token: refresh_token,
        id_token: id_token,
        client_id: client_id,
        issuer: config.issuer,
        subject: jwt.claims["sub"],
        email: jwt.claims["email"],
        scopes: config.scopes
      })
    else
      {:error, error} -> {:error, wrap_error(error)}
    end
  end

  defp verify_issuer(%{"iss" => issuer}, issuer), do: :ok

  defp verify_issuer(_claims, _issuer),
    do: {:error, "ID token issuer does not match the configured issuer"}

  defp build_credential(token, base) do
    with {:ok, access_token} <- fetch_token(token, "access_token"),
         {:ok, token_type} <- fetch_token(token, "token_type"),
         {:ok, expires_in} <- fetch_expires_in(token) do
      now = DateTime.utc_now()

      {:ok,
       struct!(
         Credential,
         Map.merge(base, %{
           access_token: access_token,
           refresh_token: token["refresh_token"] || base.refresh_token,
           id_token: token["id_token"] || base.id_token,
           token_type: token_type,
           scopes: scopes(token["scope"], base.scopes),
           expires_at: DateTime.add(now, expires_in),
           obtained_at: now
         })
       )}
    end
  end

  defp fetch_token(token, key) do
    case token[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, OAuthFailed.exception(reason: "token response is missing #{key}")}
    end
  end

  defp fetch_expires_in(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: {:ok, seconds}

  defp fetch_expires_in(_token),
    do: {:error, OAuthFailed.exception(reason: "token response is missing expires_in")}

  defp scopes(scope, _granted) when is_binary(scope), do: String.split(scope)
  defp scopes(nil, granted), do: granted

  @doc """
  Refreshes a credential, keeping its client ID and identity.

  A rotated refresh token or ID token replaces the stored one; otherwise the
  existing values are kept. Identity fields always come from the input
  credential, whose ID token was validated at exchange.
  """
  @spec refresh(config(), Credential.t()) :: {:ok, Credential.t()} | {:error, Splode.Error.t()}
  def refresh(config, %Credential{} = credential) do
    assent = assent_config(config, credential.client_id)

    identity =
      Map.take(credential, [
        :refresh_token,
        :id_token,
        :client_id,
        :issuer,
        :subject,
        :email,
        :scopes
      ])

    refresh_token = %{"refresh_token" => credential.refresh_token}

    case OAuth2.refresh_access_token(assent, refresh_token, config.token_params) do
      {:ok, token} -> build_credential(token, identity)
      {:error, error} -> {:error, wrap_error(error)}
    end
  end

  @doc """
  Revokes the credential's refresh token at `config.revoke_url` (RFC 7009).
  """
  @spec revoke(config(), Credential.t()) :: :ok | {:error, Splode.Error.t()}
  def revoke(%{revoke_url: nil}, _credential),
    do: {:error, OAuthFailed.exception(reason: "provider has no revocation endpoint")}

  def revoke(config, %Credential{} = credential) do
    body =
      URI.encode_query(
        token: credential.refresh_token,
        token_type_hint: "refresh_token",
        client_id: credential.client_id
      )

    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    assent = assent_config(config, credential.client_id)

    case Assent.Strategy.http_request(:post, config.revoke_url, body, headers, assent) do
      {:ok, %HTTPResponse{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, wrap_error(response)}
      {:error, error} -> {:error, wrap_error(error)}
    end
  end

  defp assent_config(config, client_id) do
    [
      base_url: config.issuer,
      authorize_url: config.authorize_url,
      token_url: config.token_url,
      client_id: client_id,
      auth_method: nil,
      client_authentication_method: "none",
      redirect_uri: config.redirect_uri,
      code_verifier: true,
      http_adapter: Sycophant.OAuth.HTTPAdapter,
      json_library: JSON,
      authorization_params: [scope: Enum.join(config.scopes, " ")] ++ config.authorization_params
    ]
  end

  defp random_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp wrap_error(%OAuthFailed{} = error), do: error

  defp wrap_error(%mod{response: %HTTPResponse{} = response})
       when mod in [RequestError, InvalidResponseError, UnexpectedResponseError],
       do: wrap_error(response)

  defp wrap_error(%HTTPResponse{status: status, body: body}) do
    {code, description} =
      case body do
        %{"error" => code} when is_binary(code) -> {code, body["error_description"]}
        _ -> {nil, nil}
      end

    detail = if is_binary(description), do: ": #{description}", else: ""
    OAuthFailed.exception(reason: "OAuth endpoint returned HTTP #{status}#{detail}", code: code)
  end

  defp wrap_error(reason) when is_binary(reason), do: OAuthFailed.exception(reason: reason)

  defp wrap_error(error) when is_exception(error),
    do: OAuthFailed.exception(reason: Exception.message(error))

  defp wrap_error(_error), do: OAuthFailed.exception(reason: "malformed OAuth response")
end
