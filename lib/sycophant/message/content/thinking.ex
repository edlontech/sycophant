defmodule Sycophant.Message.Content.Thinking do
  @moduledoc """
  Thinking content part for assistant messages with extended reasoning.

  Represents chain-of-thought produced by the model when reasoning/thinking
  is enabled. The `:text` field holds the raw reasoning text (Anthropic,
  Gemini, OpenAI reasoning_text). The `:summary` field holds a condensed
  summary when the provider supports it (OpenAI summary_text).

  The optional `:signature` field carries a verification token (used by
  Anthropic and AWS Bedrock) that must be passed back unmodified in
  multi-turn conversations.

  ## Examples

      iex> %Sycophant.Message.Content.Thinking{text: "Let me think about this..."}
      #Sycophant.Message.Content.Thinking<"Let me think about this...">
  """
  use TypedStruct

  typedstruct do
    field :text, String.t()
    field :summary, String.t()
    field :signature, String.t()
  end

  @doc "Deserializes a thinking content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{text: data["text"], summary: data["summary"], signature: data["signature"]}
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.Thinking do
  import Sycophant.Serializable.Helpers

  def to_map(%{text: text, summary: summary, signature: signature}) do
    compact(%{
      "__type__" => "Thinking",
      "type" => "thinking",
      "text" => text,
      "summary" => summary,
      "signature" => signature
    })
  end
end

defimpl Inspect, for: Sycophant.Message.Content.Thinking do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(thinking, opts) do
    fields =
      Enum.reject(
        [
          text: InspectHelpers.truncate(thinking.text),
          summary: InspectHelpers.truncate(thinking.summary)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Message.Content.Thinking<", to_doc(Map.new(fields), opts), ">"])
  end
end
