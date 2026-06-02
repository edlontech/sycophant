defmodule Sycophant.Reasoning do
  @moduledoc """
  Reasoning output from an LLM response.

  When a model supports extended thinking (e.g. with the `:reasoning_effort` parameter),
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
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Reasoning") |> Zoi.default("Reasoning"),
            id: Zoi.optional(Zoi.string()),
            content: Zoi.list(Sycophant.Message.Content.Thinking.t()) |> Zoi.default([]),
            encrypted_content: Zoi.optional(Zoi.string())
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
