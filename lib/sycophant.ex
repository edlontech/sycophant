defmodule Sycophant do
  @moduledoc """
  Public API for the Sycophant LLM client.
  """

  @spec generate_text([Sycophant.Message.t()], keyword()) ::
          {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}
  def generate_text(messages, opts \\ []) do
    Sycophant.Pipeline.call(messages, opts)
  end
end
