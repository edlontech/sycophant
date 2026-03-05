defmodule Sycophant.StreamChunk do
  @moduledoc """
  A streaming event delivered to the caller's stream callback.

  ## Chunk types

  * `:text_delta` - `data` is a string fragment of generated text
  * `:tool_call_delta` - `data` is `%{id: String.t(), name: String.t() | nil, arguments_delta: String.t()}`
  * `:reasoning_delta` - `data` is a string fragment of reasoning text
  * `:usage` - `data` is a `%Sycophant.Usage{}` struct
  """
  use TypedStruct

  typedstruct do
    field :type, atom(), enforce: true
    field :data, term()
    field :index, non_neg_integer()
  end
end
