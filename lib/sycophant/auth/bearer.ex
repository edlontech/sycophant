defmodule Sycophant.Auth.Bearer do
  @moduledoc """
  Default authentication strategy using a Bearer token in the
  Authorization header. Used by OpenAI, OpenRouter, and most
  OpenAI-compatible providers.
  """

  @behaviour Sycophant.Auth

  @impl true
  def middlewares(%{api_key: key}) do
    [{Tesla.Middleware.Headers, [{"authorization", "Bearer #{key}"}]}]
  end

  def middlewares(_), do: []
end
