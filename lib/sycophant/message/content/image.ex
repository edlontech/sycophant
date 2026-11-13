defmodule Sycophant.Message.Content.Image do
  @moduledoc """
  Image content part for multimodal messages.

  Provide either a `:url` for remote images or `:data` with base64-encoded
  content. When using `:data`, set `:media_type` to indicate the format
  (e.g. `"image/png"`, `"image/jpeg"`).

  Optional hints (wires that do not support them ignore them):

    * `:detail` - `:low`, `:high`, `:auto` or `:original`. Sent as `detail` on
      OpenAI Responses and Chat Completions, and as per-part `mediaResolution`
      on Gemini 3+ (`:original` maps to ultra high, `:auto` sends nothing).
    * `:cache_breakpoint` - `true` marks the end of a reusable prompt prefix
      (see `Sycophant.Message.Content.Text`).

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
            media_type: Zoi.optional(Zoi.string()),
            detail:
              Zoi.enum([low: "low", high: "high", auto: "auto", original: "original"],
                coerce: true
              )
              |> Zoi.optional(),
            cache_breakpoint: Zoi.optional(Zoi.boolean())
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
