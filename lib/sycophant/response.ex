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
  alias Sycophant.Serializable.Decoder
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

  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])

    %__MODULE__{
      text: data["text"],
      object: data["object"],
      tool_calls: decode_list(data["tool_calls"]),
      usage: decode_optional(data["usage"]),
      model: data["model"],
      raw: data["raw"],
      reasoning: decode_optional(data["reasoning"]),
      context: Decoder.from_map(Map.put(data["context"], :opts, opts), opts)
    }
  end

  defp decode_list(nil), do: []
  defp decode_list(list), do: Enum.map(list, &Decoder.from_map/1)

  defp decode_optional(nil), do: nil
  defp decode_optional(data), do: Decoder.from_map(data)
end

defimpl Sycophant.Serializable, for: Sycophant.Response do
  import Sycophant.Serializable.Helpers

  def to_map(resp) do
    compact(%{
      "__type__" => "Response",
      "text" => resp.text,
      "object" => resp.object,
      "tool_calls" => encode_list(resp.tool_calls),
      "usage" => maybe_to_map(resp.usage),
      "model" => resp.model,
      "raw" => resp.raw,
      "reasoning" => maybe_to_map(resp.reasoning),
      "context" => Sycophant.Serializable.to_map(resp.context)
    })
  end

  defp encode_list([]), do: nil
  defp encode_list(list), do: Enum.map(list, &Sycophant.Serializable.to_map/1)

  defp maybe_to_map(nil), do: nil
  defp maybe_to_map(struct), do: Sycophant.Serializable.to_map(struct)
end
