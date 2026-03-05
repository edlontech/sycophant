defmodule Sycophant.Auth do
  @moduledoc """
  Behaviour for provider-level authentication strategies.

  Each provider implements this behaviour to produce the Tesla middleware
  entries needed for its authentication scheme (Bearer token, API key
  header, SigV4, etc.). The pipeline dispatches through a registry
  so adding a new provider never requires editing the pipeline itself.
  """

  @callback middlewares(credentials :: map()) :: [Tesla.Client.middleware()]

  @registry %{
    anthropic: Sycophant.Auth.Anthropic,
    google: Sycophant.Auth.Google
  }

  @spec middlewares_for(atom(), map()) :: [Tesla.Client.middleware()]
  def middlewares_for(provider, credentials) do
    case Map.get(@registry, provider) do
      nil -> Sycophant.Auth.Bearer.middlewares(credentials)
      mod -> mod.middlewares(credentials)
    end
  end
end
