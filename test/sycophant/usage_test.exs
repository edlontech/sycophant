defmodule Sycophant.UsageTest do
  use ExUnit.Case, async: true

  alias Sycophant.Pricing
  alias Sycophant.Pricing.Component
  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder
  alias Sycophant.Usage

  defp full_pricing do
    %Pricing{
      currency: "USD",
      components: [
        %Component{id: "token.input", kind: "token", unit: "tokens", per: 1_000_000, rate: 3.0},
        %Component{id: "token.output", kind: "token", unit: "tokens", per: 1_000_000, rate: 15.0},
        %Component{
          id: "token.cache_read",
          kind: "token",
          unit: "tokens",
          per: 1_000_000,
          rate: 0.3
        },
        %Component{
          id: "token.cache_write",
          kind: "token",
          unit: "tokens",
          per: 1_000_000,
          rate: 3.75
        },
        %Component{
          id: "token.reasoning",
          kind: "token",
          unit: "tokens",
          per: 1_000_000,
          rate: 12.0
        }
      ]
    }
  end

  describe "calculate_cost/2" do
    test "calculates all costs with full token fields including reasoning" do
      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000,
        reasoning_tokens: 300_000
      }

      result = Usage.calculate_cost(usage, full_pricing())

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == 0.06
      assert result.cache_write_cost == 0.375
      assert result.reasoning_cost == 3.6
      assert result.total_cost == 3.0 + 7.5 + 0.06 + 0.375 + 3.6
      assert result.pricing == full_pricing()
    end

    test "returns nil when usage is nil" do
      assert Usage.calculate_cost(nil, full_pricing()) == nil
    end

    test "returns usage unchanged when pricing is nil" do
      usage = %Usage{input_tokens: 100, output_tokens: 50}
      assert Usage.calculate_cost(usage, nil) == usage
    end

    test "nil token fields produce nil costs" do
      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: nil,
        cache_creation_input_tokens: nil,
        reasoning_tokens: nil
      }

      result = Usage.calculate_cost(usage, full_pricing())

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.reasoning_cost == nil
      assert result.total_cost == 3.0 + 7.5
    end

    test "missing component produces nil cost" do
      pricing = %Pricing{
        currency: "USD",
        components: [
          %Component{id: "token.input", kind: "token", unit: "tokens", per: 1_000_000, rate: 3.0},
          %Component{
            id: "token.output",
            kind: "token",
            unit: "tokens",
            per: 1_000_000,
            rate: 15.0
          }
        ]
      }

      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000,
        reasoning_tokens: 300_000
      }

      result = Usage.calculate_cost(usage, pricing)

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.reasoning_cost == nil
      assert result.total_cost == 3.0 + 7.5
    end

    test "zero tokens produce zero cost" do
      usage = %Usage{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
        reasoning_tokens: 0
      }

      result = Usage.calculate_cost(usage, full_pricing())

      assert result.input_cost == 0.0
      assert result.output_cost == 0.0
      assert result.cache_read_cost == 0.0
      assert result.cache_write_cost == 0.0
      assert result.reasoning_cost == 0.0
      assert result.total_cost == 0.0
    end

    test "all tokens nil produces all nil costs" do
      usage = %Usage{}
      result = Usage.calculate_cost(usage, full_pricing())

      assert result.input_cost == nil
      assert result.output_cost == nil
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.reasoning_cost == nil
      assert result.total_cost == nil
    end

    test "uses component per value instead of hardcoded 1_000_000" do
      pricing = %Pricing{
        currency: "USD",
        components: [
          %Component{id: "token.input", kind: "token", unit: "tokens", per: 1000, rate: 0.003}
        ]
      }

      usage = %Usage{input_tokens: 5000}
      result = Usage.calculate_cost(usage, pricing)

      assert result.input_cost == 5000 * 0.003 / 1000
    end
  end

  describe "serialization round-trip" do
    test "round-trips cost fields including reasoning and pricing" do
      original = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000,
        reasoning_tokens: 300_000,
        input_cost: 3.0,
        output_cost: 7.5,
        cache_read_cost: 0.06,
        cache_write_cost: 0.375,
        reasoning_cost: 3.6,
        total_cost: 14.535,
        pricing: full_pricing()
      }

      decoded = original |> Decoder.encode() |> Decoder.decode()

      assert decoded.input_tokens == 1_000_000
      assert decoded.output_tokens == 500_000
      assert decoded.reasoning_tokens == 300_000
      assert decoded.input_cost == 3.0
      assert decoded.output_cost == 7.5
      assert decoded.cache_read_cost == 0.06
      assert decoded.cache_write_cost == 0.375
      assert decoded.reasoning_cost == 3.6
      assert decoded.total_cost == 14.535
      assert decoded.pricing.currency == "USD"
      assert length(decoded.pricing.components) == 5
    end

    test "compacts nil fields including new ones" do
      usage = %Usage{input_tokens: 100, output_tokens: 50}
      map = Serializable.to_map(usage)

      refute Map.has_key?(map, "input_cost")
      refute Map.has_key?(map, "output_cost")
      refute Map.has_key?(map, "cache_read_cost")
      refute Map.has_key?(map, "cache_write_cost")
      refute Map.has_key?(map, "reasoning_tokens")
      refute Map.has_key?(map, "reasoning_cost")
      refute Map.has_key?(map, "total_cost")
      refute Map.has_key?(map, "pricing")
    end
  end
end
