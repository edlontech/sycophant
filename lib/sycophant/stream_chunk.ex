defmodule Sycophant.StreamChunk do
  @moduledoc """
  A streaming event delivered to the caller's stream callback.

  Stream chunks arrive incrementally during a streaming request. The `:type`
  field indicates what kind of data the chunk carries.

  ## Chunk Types

    * `:text_delta` - `data` is a string fragment of generated text
    * `:tool_call_delta` - `data` is `%{id: String.t(), name: String.t() | nil, arguments_delta: String.t()}`
    * `:reasoning_delta` - `data` is a string fragment of reasoning text
    * `:usage` - `data` is a `%Sycophant.Usage{}` struct with final token counts

  ## Examples

      Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        stream: fn
          %Sycophant.StreamChunk{type: :text_delta, data: text} -> IO.write(text)
          %Sycophant.StreamChunk{type: :usage, data: usage} -> IO.inspect(usage)
          _other -> :ok
        end
      )
  """
  use TypedStruct

  typedstruct do
    field :type, atom(), enforce: true
    field :data, term()
    field :index, non_neg_integer()
  end
end
