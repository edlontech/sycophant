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
    * `:failed` - `data` is the `Splode.Error` terminating the stream; emitted immediately before the stream halts with an error (provider failure, refusal, transport error)
    * `:incomplete` - `data` is the `Splode.Error` describing why generation stopped short (token limit, content filter, truncation); emitted immediately before the stream halts
    * `:cancelled` - `data` is the `Splode.Error` describing the cancellation reason; emitted immediately before the stream halts when the provider cancels the in-flight response
    * `:done` - `data` is the final accumulator value; always the last chunk emitted on success

  ## Examples

  Simple 1-arity callback (no accumulator):

      Sycophant.generate_text("openai:gpt-4o-mini", messages,
        stream: fn
          %Sycophant.StreamChunk{type: :text_delta, data: text} -> IO.write(text)
          %Sycophant.StreamChunk{type: :usage, data: usage} -> IO.inspect(usage)
          _other -> :ok
        end
      )

  2-arity accumulator callback (`{initial_acc, fun}`):

      Sycophant.generate_text("openai:gpt-4o-mini", messages,
        stream: {[], fn
          %Sycophant.StreamChunk{type: :text_delta, data: text}, acc -> [text | acc]
          _chunk, acc -> acc
        end}
      )
  """
  use TypedStruct

  typedstruct do
    field :type, atom(), enforce: true
    field :data, term()
    field :index, non_neg_integer()
  end
end

defimpl Inspect, for: Sycophant.StreamChunk do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(chunk, opts) do
    fields =
      Enum.reject(
        [type: chunk.type, data: InspectHelpers.truncate_inspect(chunk.data), index: chunk.index],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.StreamChunk<", to_doc(Map.new(fields), opts), ">"])
  end
end
