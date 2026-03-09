defmodule Sycophant.Usage do
  @moduledoc """
  Token usage information from an LLM response.
  """
  use TypedStruct

  typedstruct do
    field :input_tokens, non_neg_integer()
    field :output_tokens, non_neg_integer()
    field :cache_creation_input_tokens, non_neg_integer()
    field :cache_read_input_tokens, non_neg_integer()
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      cache_creation_input_tokens: data["cache_creation_input_tokens"],
      cache_read_input_tokens: data["cache_read_input_tokens"]
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Usage do
  import Sycophant.Serializable.Helpers

  def to_map(u) do
    compact(%{
      "__type__" => "Usage",
      "input_tokens" => u.input_tokens,
      "output_tokens" => u.output_tokens,
      "cache_creation_input_tokens" => u.cache_creation_input_tokens,
      "cache_read_input_tokens" => u.cache_read_input_tokens
    })
  end
end
