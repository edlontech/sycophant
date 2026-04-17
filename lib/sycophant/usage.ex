defmodule Sycophant.Usage do
  @moduledoc """
  Token usage statistics from an LLM response.

  Reports input and output token counts, plus optional cache hit/miss
  information for providers that support prompt caching.

  ## Examples

      iex> %Sycophant.Usage{input_tokens: 10, output_tokens: 25}
      #Sycophant.Usage<%{in: 10, out: 25}>
  """
  alias Sycophant.Pricing

  defstruct [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens,
    :reasoning_tokens,
    :input_cost,
    :output_cost,
    :cache_read_cost,
    :cache_write_cost,
    :reasoning_cost,
    :total_cost,
    :pricing
  ]

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          input_cost: float() | nil,
          output_cost: float() | nil,
          cache_read_cost: float() | nil,
          cache_write_cost: float() | nil,
          reasoning_cost: float() | nil,
          total_cost: float() | nil,
          pricing: Pricing.t() | nil
        }

  @doc "Reconstructs a Usage struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      cache_creation_input_tokens: data["cache_creation_input_tokens"],
      cache_read_input_tokens: data["cache_read_input_tokens"],
      reasoning_tokens: data["reasoning_tokens"],
      input_cost: data["input_cost"],
      output_cost: data["output_cost"],
      cache_read_cost: data["cache_read_cost"],
      cache_write_cost: data["cache_write_cost"],
      reasoning_cost: data["reasoning_cost"],
      total_cost: data["total_cost"],
      pricing: if(data["pricing"], do: Pricing.from_map(data["pricing"]))
    }
  end

  @doc """
  Calculates cost fields from token counts and a `Pricing` struct.

  Looks up each token component by ID (e.g. `"token.input"`, `"token.output"`)
  and computes cost as `tokens * rate / per`. Missing components yield nil costs.
  """
  @spec calculate_cost(t() | nil, Pricing.t() | nil) :: t() | nil
  def calculate_cost(nil, _pricing), do: nil
  def calculate_cost(usage, nil), do: usage

  def calculate_cost(usage, %Pricing{} = pricing) do
    input = component_cost(usage.input_tokens, pricing, "token.input")
    output = component_cost(usage.output_tokens, pricing, "token.output")
    cache_read = component_cost(usage.cache_read_input_tokens, pricing, "token.cache_read")
    cache_write = component_cost(usage.cache_creation_input_tokens, pricing, "token.cache_write")
    reasoning = component_cost(usage.reasoning_tokens, pricing, "token.reasoning")
    total = sum_costs([input, output, cache_read, cache_write, reasoning])

    %{
      usage
      | input_cost: input,
        output_cost: output,
        cache_read_cost: cache_read,
        cache_write_cost: cache_write,
        reasoning_cost: reasoning,
        total_cost: total,
        pricing: pricing
    }
  end

  defp component_cost(nil, _pricing, _id), do: nil

  defp component_cost(tokens, %Pricing{} = pricing, id) do
    case Pricing.find_component(pricing, id) do
      nil -> nil
      comp -> tokens * comp.rate / comp.per
    end
  end

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
      "reasoning_tokens" => u.reasoning_tokens,
      "input_cost" => u.input_cost,
      "output_cost" => u.output_cost,
      "cache_read_cost" => u.cache_read_cost,
      "cache_write_cost" => u.cache_write_cost,
      "reasoning_cost" => u.reasoning_cost,
      "total_cost" => u.total_cost,
      "pricing" => if(u.pricing, do: Sycophant.Serializable.to_map(u.pricing))
    })
  end
end

defimpl Inspect, for: Sycophant.Usage do
  import Inspect.Algebra

  def inspect(usage, opts) do
    fields =
      Enum.reject(
        [
          in: usage.input_tokens,
          out: usage.output_tokens,
          reasoning: usage.reasoning_tokens,
          cost: usage.total_cost
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Usage<", to_doc(Map.new(fields), opts), ">"])
  end
end
