defmodule Sycophant.Auth.Anthropic do
  @moduledoc """
  Authentication strategy for the Anthropic API.

  Uses the `x-api-key` header and includes the required
  `anthropic-version` header for API compatibility. The version
  can be overridden via the `:anthropic_version` key in credentials.
  """

  @behaviour Sycophant.Auth

  @default_anthropic_version "2023-06-01"

  @impl true
  def middlewares(%{api_key: key} = credentials) do
    version = Map.get(credentials, :anthropic_version, @default_anthropic_version)

    [{Tesla.Middleware.Headers, [{"x-api-key", key}, {"anthropic-version", version}]}]
  end

  def middlewares(_), do: []
end
