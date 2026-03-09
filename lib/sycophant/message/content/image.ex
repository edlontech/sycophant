defmodule Sycophant.Message.Content.Image do
  @moduledoc """
  Image content part for multimodal messages.

  Either `url` or `data` (base64) should be provided.
  """
  use TypedStruct

  typedstruct do
    field :url, String.t()
    field :data, String.t()
    field :media_type, String.t()
  end

  @doc "Deserializes an image content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{url: data["url"], data: data["data"], media_type: data["media_type"]}
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.Image do
  import Sycophant.Serializable.Helpers

  def to_map(img) do
    compact(%{
      "__type__" => "Image",
      "type" => "image",
      "url" => img.url,
      "data" => img.data,
      "media_type" => img.media_type
    })
  end
end
