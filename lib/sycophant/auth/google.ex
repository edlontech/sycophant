defmodule Sycophant.Auth.Google do
  @moduledoc """
  Authentication strategy for the Google Gemini API.

  Uses the `x-goog-api-key` header for API key authentication.
  """

  @behaviour Sycophant.Auth

  @impl true
  def middlewares(%{api_key: key}) do
    [{Tesla.Middleware.Headers, [{"x-goog-api-key", key}]}]
  end

  def middlewares(_), do: []
end
