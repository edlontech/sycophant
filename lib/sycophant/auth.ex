defmodule Sycophant.Auth do
  @moduledoc """
  Behaviour for provider-level authentication strategies.

  Each provider implements this behaviour to produce the Tesla middleware
  entries needed for its authentication scheme (Bearer token, API key
  header, SigV4, etc.). The pipeline dispatches through a registry
  so adding a new provider never requires editing the pipeline itself.
  """

  @callback middlewares(credentials :: map()) :: [Tesla.Client.middleware()]
  @callback path_params(credentials :: map()) :: keyword()

  @optional_callbacks [path_params: 1]

  @registry %{
    amazon_bedrock: Sycophant.Auth.Bedrock,
    anthropic: Sycophant.Auth.Anthropic,
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
