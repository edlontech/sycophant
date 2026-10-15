defmodule Sycophant.Usage do
  @moduledoc """
  Token usage statistics from an LLM response.

  Reports input and output token counts, plus optional cache hit/miss
  information for providers that support prompt caching.

  Following the OpenTelemetry GenAI conventions, `input_tokens` is the total
  prompt size on every provider: it includes `cache_read_input_tokens` and
  `cache_creation_input_tokens`. Likewise `output_tokens` includes
  `reasoning_tokens`.

  ## Examples

      iex> %Sycophant.Usage{input_tokens: 10, output_tokens: 25}
      #Sycophant.Usage<%{in: 10, out: 25}>
  """
  alias Sycophant.Pricing

  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Usage") |> Zoi.default("Usage"),
            input_tokens: Zoi.optional(Zoi.integer()),
            output_tokens: Zoi.optional(Zoi.integer()),
            cache_creation_input_tokens: Zoi.optional(Zoi.integer()),
            cache_read_input_tokens: Zoi.optional(Zoi.integer()),
            reasoning_tokens: Zoi.optional(Zoi.integer()),
            input_cost: Zoi.optional(Zoi.float()),
            output_cost: Zoi.optional(Zoi.float()),
            cache_read_cost: Zoi.optional(Zoi.float()),
            cache_write_cost: Zoi.optional(Zoi.float()),
            reasoning_cost: Zoi.optional(Zoi.float()),
            total_cost: Zoi.optional(Zoi.float()),
            pricing: Zoi.optional(Sycophant.Pricing.t())

  @doc """
  Calculates cost fields from token counts and a `Pricing` struct.

  Looks up each token component by ID (e.g. `"token.input"`, `"token.output"`)
  and computes cost as `tokens * rate / per`. Missing components yield nil costs,
  except cache reads and writes, which fall back to the input rate, and
  reasoning, which falls back to the output rate.

  Only the uncached part of `input_tokens` is billed at the input rate and only
  the non-reasoning part of `output_tokens` at the output rate; the rest is
  billed through the cache and reasoning components.
  """
  @spec calculate_cost(t() | nil, Pricing.t() | nil) :: t() | nil
  def calculate_cost(nil, _pricing), do: nil
  def calculate_cost(usage, nil), do: usage

  def calculate_cost(usage, %Pricing{} = pricing) do
    input = component_cost(uncached_input_tokens(usage), pricing, "token.input")
    output = component_cost(non_reasoning_output_tokens(usage), pricing, "token.output")

    cache_read =
      component_cost(usage.cache_read_input_tokens, pricing, ["token.cache_read", "token.input"])

    cache_write =
      component_cost(usage.cache_creation_input_tokens, pricing, [
        "token.cache_write",
        "token.input"
      ])

    reasoning =
      component_cost(usage.reasoning_tokens, pricing, ["token.reasoning", "token.output"])

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

  defp uncached_input_tokens(%{input_tokens: nil}), do: nil

  defp uncached_input_tokens(usage) do
    cached = (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0)
    max(usage.input_tokens - cached, 0)
  end

  defp non_reasoning_output_tokens(%{output_tokens: nil}), do: nil

  defp non_reasoning_output_tokens(usage),
    do: max(usage.output_tokens - (usage.reasoning_tokens || 0), 0)

  defp component_cost(nil, _pricing, _ids), do: nil

  defp component_cost(tokens, %Pricing{} = pricing, ids) do
    case Enum.find_value(List.wrap(ids), &Pricing.find_component(pricing, &1)) do
      nil -> nil
      comp -> tokens * comp.rate / comp.per
    end
  end

  defp sum_costs(costs) do
    non_nil = Enum.reject(costs, &is_nil/1)
    if non_nil == [], do: nil, else: Enum.sum(non_nil)
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
