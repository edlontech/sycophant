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
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Image") |> Zoi.default("Image"),
            type: Zoi.literal("image") |> Zoi.default("image"),
            url: Zoi.optional(Zoi.string()),
            data: Zoi.optional(Zoi.string()),
            media_type: Zoi.optional(Zoi.string())
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
