defmodule Sycophant.Auth do
  @moduledoc """
  Behaviour and registry for provider authentication strategies.

  Each provider implements this behaviour to produce Tesla middleware
  entries for its authentication scheme. The pipeline dispatches through
  an internal registry, so adding a new provider never requires editing
  the pipeline.

  ## Built-in Strategies

    * `Sycophant.Auth.Bearer` - Bearer token (OpenAI, OpenRouter, and OpenAI-compatible)
    * `Sycophant.Auth.Anthropic` - `x-api-key` header with version header
    * `Sycophant.Auth.Google` - `x-goog-api-key` header
    * `Sycophant.Auth.Bedrock` - AWS SigV4 request signing
    * `Sycophant.Auth.Azure` - Bearer token with `api-version` query parameter

  Unregistered providers fall back to the Bearer strategy.
  """

  @callback middlewares(credentials :: map()) :: [Tesla.Client.middleware()]
  @callback path_params(credentials :: map()) :: keyword()

  @optional_callbacks [path_params: 1]

  @registry %{
    amazon_bedrock: Sycophant.Auth.Bedrock,
    anthropic: Sycophant.Auth.Anthropic,
    azure: Sycophant.Auth.Azure,
    google: Sycophant.Auth.Google
  }

  @doc """
  Returns the list of Tesla middlewares needed to authenticate requests for
  the given `provider`. Looks up the provider in the internal registry and
  delegates to its `middlewares/1` callback. Falls back to a generic Bearer
  token strategy for unregistered providers.
  """
  @spec middlewares_for(atom(), map()) :: [Tesla.Client.middleware()]
  def middlewares_for(provider, credentials) do
    case Map.get(@registry, provider) do
      nil -> Sycophant.Auth.Bearer.middlewares(credentials)
      mod -> mod.middlewares(credentials)
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
    case Map.get(@registry, provider) do
      nil ->
        []

      mod ->
        if function_exported?(mod, :path_params, 1),
          do: mod.path_params(credentials),
          else: []
    end
  end
end
