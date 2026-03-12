defmodule Sycophant.Message.Content.Image do
  @moduledoc """
  Image content part for multimodal messages.

  Provide either a `:url` for remote images or `:data` with base64-encoded
  content. When using `:data`, set `:media_type` to indicate the format
  (e.g. `"image/png"`, `"image/jpeg"`).

  ## Examples

      # URL-based image
      %Sycophant.Message.Content.Image{url: "https://example.com/photo.jpg"}

      # Base64-encoded image
      %Sycophant.Message.Content.Image{
        data: "iVBORw0KGgo...",
        media_type: "image/png"
      }
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

defimpl Inspect, for: Sycophant.Message.Content.Image do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(img, opts) do
    fields =
      Enum.reject(
        [url: img.url, data: InspectHelpers.redact(img.data), media_type: img.media_type],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Message.Content.Image<", to_doc(Map.new(fields), opts), ">"])
  end
end
