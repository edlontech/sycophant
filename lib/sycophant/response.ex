defmodule Sycophant.Response do
  @moduledoc """
  The result of an LLM call.

  Contains the generated text or object, any tool calls requested,
  token usage, and an internal `Context` that enables conversation
  continuation via `Sycophant.generate_text(response, new_message)`.

  Use `Response.messages/1` to inspect the conversation history.
  """
  use TypedStruct

  alias Sycophant.Context
  alias Sycophant.Reasoning
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  typedstruct do
    field :text, String.t()
    field :object, map()
    field :tool_calls, [ToolCall.t()], default: []
    field :usage, Usage.t()
    field :model, String.t()
    field :raw, map()
    field :reasoning, Reasoning.t()
    field :context, Context.t(), enforce: true
  end

  @spec messages(t()) :: [Sycophant.Message.t()]
  def messages(%__MODULE__{context: context}), do: context.messages
end
