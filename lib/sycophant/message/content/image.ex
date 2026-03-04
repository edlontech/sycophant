defmodule Sycophant.Message.Content.Image do
  @moduledoc """
  Image content part for multimodal messages.

  Either `url` or `data` (base64) should be provided.
  """
  use TypedStruct

  typedstruct do
    field(:url, String.t())
    field(:data, String.t())
    field(:media_type, String.t())
  end
end
