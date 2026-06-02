defmodule Sycophant.Message.Content.Text do
  @moduledoc """
  Text content part for multimodal messages.

  Used when a message contains a mix of text and other content types
  like images. For text-only messages, pass a plain string to the
  message constructors instead.

  The optional `:citations` field holds the `Sycophant.Citation` structs a
  provider attached to this span of assistant text (currently Anthropic).

  ## Examples

      iex> %Sycophant.Message.Content.Text{text: "Describe this image"}
      #Sycophant.Message.Content.Text<"Describe this image">
  """
  @enforce_keys [:text]
  defstruct [:text, citations: nil]

  @type t :: %__MODULE__{
          text: String.t(),
          citations: [Sycophant.Citation.t()] | nil
        }

  @doc "Deserializes a text content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(%{"text" => text} = data) do
    %__MODULE__{text: text, citations: decode_citations(data["citations"])}
  end

  defp decode_citations(nil), do: nil

  defp decode_citations(list) when is_list(list),
    do: Enum.map(list, &Sycophant.Serializable.Decoder.from_map/1)
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.Text do
  import Sycophant.Serializable.Helpers

  def to_map(%{text: text, citations: citations}) do
    compact(%{
      "__type__" => "Text",
      "type" => "text",
      "text" => text,
      "citations" => encode_citations(citations)
    })
  end

  defp encode_citations(nil), do: nil
  defp encode_citations([]), do: nil
  defp encode_citations(list), do: Enum.map(list, &Sycophant.Serializable.to_map/1)
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
