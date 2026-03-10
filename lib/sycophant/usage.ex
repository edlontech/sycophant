defmodule Sycophant.Usage do
  @moduledoc """
  Token usage statistics from an LLM response.

  Reports input and output token counts, plus optional cache hit/miss
  information for providers that support prompt caching.

  ## Examples

      iex> %Sycophant.Usage{input_tokens: 10, output_tokens: 25}
      %Sycophant.Usage{input_tokens: 10, output_tokens: 25, cache_creation_input_tokens: nil, cache_read_input_tokens: nil, input_cost: nil, output_cost: nil, cache_read_cost: nil, cache_write_cost: nil, total_cost: nil}
  """
  use TypedStruct

  typedstruct do
    field :input_tokens, non_neg_integer()
    field :output_tokens, non_neg_integer()
    field :cache_creation_input_tokens, non_neg_integer()
    field :cache_read_input_tokens, non_neg_integer()
    field :input_cost, float()
    field :output_cost, float()
    field :cache_read_cost, float()
    field :cache_write_cost, float()
    field :total_cost, float()
  end

  @doc "Reconstructs a Usage struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      cache_creation_input_tokens: data["cache_creation_input_tokens"],
      cache_read_input_tokens: data["cache_read_input_tokens"],
      input_cost: data["input_cost"],
      output_cost: data["output_cost"],
      cache_read_cost: data["cache_read_cost"],
      cache_write_cost: data["cache_write_cost"],
      total_cost: data["total_cost"]
    }
  end

  @doc """
  Calculates cost fields from token counts and a cost rate map.

  The cost map uses rates per million tokens:
  `%{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}`
  """
  @spec calculate_cost(t() | nil, map() | nil) :: t() | nil
  def calculate_cost(nil, _cost_map), do: nil
  def calculate_cost(usage, nil), do: usage

  def calculate_cost(usage, cost_map) do
    input = token_cost(usage.input_tokens, cost_map[:input])
    output = token_cost(usage.output_tokens, cost_map[:output])
    cache_read = token_cost(usage.cache_read_input_tokens, cost_map[:cache_read])
    cache_write = token_cost(usage.cache_creation_input_tokens, cost_map[:cache_write])
    total = sum_costs([input, output, cache_read, cache_write])

    %{
      usage
      | input_cost: input,
        output_cost: output,
        cache_read_cost: cache_read,
        cache_write_cost: cache_write,
        total_cost: total
    }
  end

  defp token_cost(nil, _rate), do: nil
  defp token_cost(_tokens, nil), do: nil
  defp token_cost(tokens, rate), do: tokens * rate / 1_000_000

  defp sum_costs(costs) do
    non_nil = Enum.reject(costs, &is_nil/1)
    if non_nil == [], do: nil, else: Enum.sum(non_nil)
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
      "cache_read_input_tokens" => u.cache_read_input_tokens,
      "input_cost" => u.input_cost,
      "output_cost" => u.output_cost,
      "cache_read_cost" => u.cache_read_cost,
      "cache_write_cost" => u.cache_write_cost,
      "total_cost" => u.total_cost
    })
  end
end
