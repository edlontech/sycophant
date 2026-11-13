defmodule Sycophant.Message.Content.Text do
  @moduledoc """
  Text content part for multimodal messages.

  Used when a message contains a mix of text and other content types
  like images. For text-only messages, pass a plain string to the
  message constructors instead.

  The optional `:citations` field holds the `Sycophant.Citation` structs a
  provider attached to this span of assistant text (currently Anthropic).

  Set `:cache_breakpoint` to `true` to mark the end of a reusable prompt
  prefix: `prompt_cache_breakpoint` on OpenAI Responses and Chat Completions,
  block `cache_control` on Anthropic, and a `cachePoint` block on Bedrock.
  Gemini ignores it. System messages are joined into a plain string on OpenAI
  Responses and Anthropic, so breakpoints there only apply on Bedrock and
  Chat Completions.

  ## Examples

      iex> %Sycophant.Message.Content.Text{text: "Describe this image"}
      #Sycophant.Message.Content.Text<"Describe this image">
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Text") |> Zoi.default("Text"),
            type: Zoi.literal("text") |> Zoi.default("text"),
            text: Zoi.string(),
            citations: Zoi.list(Sycophant.Citation.t()) |> Zoi.optional(),
            cache_breakpoint: Zoi.optional(Zoi.boolean())
end

defimpl Inspect, for: Sycophant.Message.Content.Text do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(%{citations: citations} = text, opts)
      when is_list(citations) and citations != [] do
    concat([
      "#Sycophant.Message.Content.Text<",
      to_doc(InspectHelpers.truncate(text.text), opts),
      " (#{length(citations)} citations)>"
    ])
  end

  def inspect(text, opts) do
    concat([
      "#Sycophant.Message.Content.Text<",
      to_doc(InspectHelpers.truncate(text.text), opts),
      ">"
    ])
  end
end
