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
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Thinking") |> Zoi.default("Thinking"),
            type: Zoi.literal("thinking") |> Zoi.default("thinking"),
            id: Zoi.optional(Zoi.string()),
            text: Zoi.optional(Zoi.string()),
            summary: Zoi.optional(Zoi.string()),
            signature: Zoi.optional(Zoi.string())
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
