defmodule Sycophant.Response do
  @moduledoc """
  The result of an LLM call.

  Contains the generated text or structured object, any tool calls requested
  by the model, token usage statistics, and an opaque `Context` that enables
  conversation continuation.

  ## Continuing Conversations

  Use `response.context` with `Context.add/2` to continue the conversation:

      {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
      ctx = response.context |> Context.add(Message.user("Tell me more"))
      {:ok, follow_up} = Sycophant.generate_text("openai:gpt-4o-mini", ctx)

  ## Inspecting History

  Use `messages/1` to retrieve the full conversation history:

      Response.messages(response)
      #=> [%Message{role: :user, ...}, %Message{role: :assistant, ...}]

  ## Serialization

  Responses implement `Sycophant.Serializable` for JSON persistence:

      json = Sycophant.Serializable.Decoder.encode(response)
      restored = Sycophant.Serializable.Decoder.decode(json)
  """
  use TypedStruct

  alias Sycophant.Context
  alias Sycophant.Reasoning
  alias Sycophant.Serializable.Decoder
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  @type finish_reason() ::
          :stop
          | :tool_use
          | :max_tokens
          | :content_filter
          | :recitation
          | :error
          | :incomplete
          | :unknown
          | nil

  @valid_finish_reasons ~w(stop tool_use max_tokens content_filter recitation error incomplete unknown)a

  typedstruct do
    field :text, String.t()
    field :object, map()
    field :tool_calls, [ToolCall.t()], default: []
    field :usage, Usage.t()
    field :model, String.t()
    field :raw, map()
    field :reasoning, Reasoning.t()
    field :finish_reason, finish_reason()
    field :context, Context.t(), enforce: true
    field :metadata, map(), default: %{}
  end

  @doc """
  Returns the full conversation message history from the response context.

  The list includes all user, assistant, system, and tool result messages
  exchanged during the conversation.
  """
  @spec messages(t()) :: [Sycophant.Message.t()]
  def messages(%__MODULE__{context: context}), do: context.messages

  @doc """
  Reconstructs a `Response` from a serialized map produced by `Sycophant.Serializable`.
  """
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
      finish_reason: decode_finish_reason(data["finish_reason"]),
      context: Decoder.from_map(Map.put(data["context"], :opts, opts), opts),
      metadata: decode_metadata(data["metadata"])
    }
  end

  defp decode_list(nil), do: []
  defp decode_list(list), do: Enum.map(list, &Decoder.from_map/1)

  defp decode_optional(nil), do: nil
  defp decode_optional(data), do: Decoder.from_map(data)

  defp decode_metadata(nil), do: %{}
  defp decode_metadata(meta) when is_map(meta), do: atomize_keys(meta)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(value), do: value

  defp decode_finish_reason(nil), do: nil

  defp decode_finish_reason(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid_finish_reasons, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end
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
      "finish_reason" => if(resp.finish_reason, do: Atom.to_string(resp.finish_reason)),
      "context" => Sycophant.Serializable.to_map(resp.context),
      "metadata" => encode_metadata(resp.metadata)
    })
  end

  defp encode_list([]), do: nil
  defp encode_list(list), do: Enum.map(list, &Sycophant.Serializable.to_map/1)

  defp maybe_to_map(nil), do: nil
  defp maybe_to_map(struct), do: Sycophant.Serializable.to_map(struct)

  defp encode_metadata(meta) when map_size(meta) == 0, do: nil

  defp encode_metadata(meta) do
    stringify_keys(meta)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(value), do: value
end
