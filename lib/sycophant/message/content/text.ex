defmodule Sycophant.Message.Content.Text do
  @moduledoc """
  Text content part for multimodal messages.

  Used when a message contains a mix of text and other content types
  like images. For text-only messages, pass a plain string to the
  message constructors instead.

  ## Examples

      iex> %Sycophant.Message.Content.Text{text: "Describe this image"}
      %Sycophant.Message.Content.Text{text: "Describe this image"}
  """
  use TypedStruct

  typedstruct do
    field :text, String.t(), enforce: true
  end

  @doc "Deserializes a text content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(%{"text" => text}), do: %__MODULE__{text: text}
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.Text do
  def to_map(%{text: text}), do: %{"__type__" => "Text", "type" => "text", "text" => text}
end
