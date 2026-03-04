defmodule Sycophant.Usage do
  @moduledoc """
  Token usage information from an LLM response.
  """
  use TypedStruct

  typedstruct do
    field(:input_tokens, non_neg_integer())
    field(:output_tokens, non_neg_integer())
  end
end
