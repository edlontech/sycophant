defmodule Sycophant.Reasoning do
  @moduledoc """
  Reasoning output from an LLM response.

  When a model supports extended thinking (e.g. with the `:reasoning` parameter),
  the chain-of-thought is available in `response.reasoning.content` as a list
  of `Content.Thinking` structs. Each thinking block may carry `:text` (raw
  chain-of-thought), `:summary` (condensed summary), or both, depending on
  the provider.

  The `:encrypted_content` field carries an opaque blob for multi-turn reasoning
  continuity (Anthropic redacted_thinking, OpenAI encrypted_content).

  Each entry in `:content` maps directly to a `Content.Thinking` part, and
  `:encrypted_content` maps to a `Content.RedactedThinking` part when building
  assistant messages for multi-turn conversations.

  ## Examples

      iex> alias Sycophant.Message.Content.Thinking
      iex> %Sycophant.Reasoning{content: [%Thinking{text: "Let me think..."}]}
      #Sycophant.Reasoning<%{content: [%{text: "Let me think..."}]}>
  """
  use TypedStruct

  alias Sycophant.Message.Content

  typedstruct do
    field :content, [Content.Thinking.t()], default: []
    field :encrypted_content, String.t()
  end

  @doc "Deserializes reasoning output from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      content: decode_content(data["content"]),
      encrypted_content: data["encrypted_content"]
    }
  end

  defp decode_content(nil), do: []

  defp decode_content(items) when is_list(items) do
    Enum.map(items, &Content.Thinking.from_map/1)
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Reasoning do
  import Sycophant.Serializable.Helpers

  def to_map(r) do
    compact(%{
      "__type__" => "Reasoning",
      "content" => encode_content(r.content),
      "encrypted_content" => r.encrypted_content
    })
  end

  defp encode_content([]), do: nil

  defp encode_content(items) do
    Enum.map(items, &Sycophant.Serializable.to_map/1)
  end
end

defimpl Inspect, for: Sycophant.Reasoning do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(reasoning, opts) do
    fields =
      Enum.reject(
        [
          content: inspect_content(reasoning.content),
          encrypted_content: InspectHelpers.redact(reasoning.encrypted_content)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Reasoning<", to_doc(Map.new(fields), opts), ">"])
  end

  defp inspect_content([]), do: nil
  defp inspect_content(items), do: Enum.map(items, &inspect_thinking/1)

  defp inspect_thinking(item) do
    [text: item.text, summary: item.summary]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, InspectHelpers.truncate(v)} end)
    |> Map.new()
  end
end
