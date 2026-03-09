defmodule Sycophant do
  @moduledoc """
  Public API for the Sycophant LLM client.
  """

  alias Sycophant.Message
  alias Sycophant.Params
  alias Sycophant.Response

  @doc """
  Sends a text generation request to the configured LLM provider.

  Accepts either a list of `Message` structs with keyword options, or a previous
  `Response` together with a follow-up `Message` to continue the conversation.
  When a `Response` is passed, the model, tools, streaming, and parameter settings
  are automatically carried over from its context.
  """
  @spec generate_text([Message.t()] | Response.t(), keyword() | Message.t()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_text(messages_or_response, opts_or_message \\ [])

  def generate_text(messages, opts) when is_list(messages) do
    Sycophant.Pipeline.call(messages, opts)
  end

  def generate_text(%Response{context: context}, %Message{} = message) do
    messages = context.messages ++ [message]

    opts =
      [
        model: context.model,
        tools: context.tools,
        stream: context.stream,
        provider_params: context.provider_params
      ] ++ params_to_opts(context.params)

    Sycophant.Pipeline.call(messages, opts)
  end

  @doc """
  Generates a structured object whose output is validated against a Zoi schema.

  Works like `generate_text/2` but additionally instructs the provider to return
  output conforming to `schema`. When continuing from a previous `Response`, the
  schema stored in its context is reused automatically.
  """
  @spec generate_object([Message.t()] | Response.t(), Zoi.schema() | Message.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_object(messages_or_response, schema_or_message, opts \\ [])

  def generate_object(messages, schema, opts) when is_list(messages) do
    Sycophant.Pipeline.call(messages, Keyword.put(opts, :response_schema, schema))
  end

  def generate_object(%Response{context: context}, %Message{} = message, _opts) do
    messages = context.messages ++ [message]

    opts =
      [
        model: context.model,
        tools: context.tools,
        stream: context.stream,
        provider_params: context.provider_params,
        response_schema: context.response_schema
      ] ++ params_to_opts(context.params)

    Sycophant.Pipeline.call(messages, opts)
  end

  defp params_to_opts(%Params{} = params) do
    params
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.new()
  end

  defp params_to_opts(nil), do: []
end
