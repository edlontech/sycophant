defmodule Sycophant.Message.Content.Text do
  @moduledoc """
  Text content part for multimodal messages.
  """
  use TypedStruct

  typedstruct do
    field(:text, String.t(), enforce: true)
  end
end
