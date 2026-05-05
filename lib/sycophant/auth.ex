defmodule Sycophant.Auth do
  @moduledoc """
  Behaviour and registry for provider authentication strategies.

  Each provider implements this behaviour to produce Tesla middleware
  entries for its authentication scheme. The pipeline dispatches through
  `Sycophant.Registry`, so adding a new provider never requires editing
  the pipeline.

  ## Built-in Strategies

    * `Sycophant.Auth.Bearer` - Bearer token (OpenAI, OpenRouter, and OpenAI-compatible)
    * `Sycophant.Auth.Anthropic` - `x-api-key` header with version header
    * `Sycophant.Auth.Google` - `x-goog-api-key` header
    * `Sycophant.Auth.Bedrock` - AWS SigV4 request signing
    * `Sycophant.Auth.Azure` - Bearer token with `api-version` query parameter
    * `Sycophant.Auth.GithubCopilot` - Bearer token with token exchange + caching

  Unregistered providers fall back to the Bearer strategy.

  ## Optional callbacks

    * `path_params/1` - returns provider-specific URL path parameters
    * `prepare_credentials/1` - mutates the credential map before transport
      assembly. Used by providers that need to perform side-effecting work
      (token exchange, signing nonce, etc.) and surface results back into
      the credentials map (e.g. `:base_url`, `:copilot_token`).
  """

  @callback middlewares(credentials :: map()) :: [Tesla.Client.middleware()]
  @callback path_params(credentials :: map()) :: keyword()
  @callback prepare_credentials(credentials :: map()) ::
              {:ok, map()} | {:error, Splode.Error.t()}

  @optional_callbacks [path_params: 1, prepare_credentials: 1]

  @doc """
  Returns the list of Tesla middlewares needed to authenticate requests for
  the given `provider`. Looks up the provider in `Sycophant.Registry` and
  delegates to its `middlewares/1` callback. Falls back to a generic Bearer
  token strategy for unregistered providers.
  """
  @spec middlewares_for(atom(), map()) :: [Tesla.Client.middleware()]
  def middlewares_for(provider, credentials) do
    case Sycophant.Registry.fetch_auth(provider) do
      {:ok, mod} -> mod.middlewares(credentials)
      :error -> Sycophant.Auth.Bearer.middlewares(credentials)
    end
  end

  @doc """
  Returns provider-specific path parameters derived from the given credentials.

  Some providers (e.g. Bedrock) require dynamic URL segments such as region or
  model ID. If the provider module implements the optional `path_params/1`
  callback, those parameters are returned; otherwise an empty list is returned.
  """
  @spec path_params_for(atom(), map()) :: keyword()
  def path_params_for(provider, credentials) do
    case Sycophant.Registry.fetch_auth(provider) do
      {:ok, mod} ->
        Code.ensure_loaded!(mod)

        if function_exported?(mod, :path_params, 1),
          do: mod.path_params(credentials),
          else: []

      :error ->
        []
    end
  end

  @doc """
  Optionally mutates `credentials` before transport assembly.

  Providers that need side-effecting work (e.g. token exchange) implement
  `prepare_credentials/1` to populate fields like `:base_url` or session
  tokens into the credentials map. The pipeline calls this between
  `Credentials.resolve/2` and `transport_opts/3`, so any `:base_url` or
  auth-relevant field set here flows naturally into the upstream Tesla
  middleware stack.

  Returns `{:ok, credentials}` unchanged for providers without an
  implementation.
  """
  @spec prepare_credentials_for(atom(), map()) ::
          {:ok, map()} | {:error, Splode.Error.t()}
  def prepare_credentials_for(provider, credentials) do
    case Sycophant.Registry.fetch_auth(provider) do
      {:ok, mod} ->
        Code.ensure_loaded!(mod)

        if function_exported?(mod, :prepare_credentials, 1),
          do: mod.prepare_credentials(credentials),
          else: {:ok, credentials}

      :error ->
        {:ok, credentials}
    end
  end
end
