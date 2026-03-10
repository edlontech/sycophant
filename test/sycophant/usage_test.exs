defmodule Sycophant.UsageTest do
  use ExUnit.Case, async: true

  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder
  alias Sycophant.Usage

  @full_cost_map %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}

  describe "calculate_cost/2" do
    test "calculates all costs with full token fields and cost map" do
      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000
      }

      result = Usage.calculate_cost(usage, @full_cost_map)

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == 0.06
      assert result.cache_write_cost == 0.375
      assert result.total_cost == 3.0 + 7.5 + 0.06 + 0.375
    end

    test "returns nil when usage is nil" do
      assert Usage.calculate_cost(nil, @full_cost_map) == nil
    end

    test "returns usage unchanged when cost_map is nil" do
      usage = %Usage{input_tokens: 100, output_tokens: 50}
      assert Usage.calculate_cost(usage, nil) == usage
    end

    test "nil token fields produce nil costs" do
      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: nil,
        cache_creation_input_tokens: nil
      }

      result = Usage.calculate_cost(usage, @full_cost_map)

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.total_cost == 3.0 + 7.5
    end

    test "missing rates in cost map produce nil costs" do
      usage = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000
      }

      result = Usage.calculate_cost(usage, %{input: 3.0, output: 15.0})

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.total_cost == 3.0 + 7.5
    end

    test "zero tokens produce zero cost" do
      usage = %Usage{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0
      }

      result = Usage.calculate_cost(usage, @full_cost_map)

      assert result.input_cost == 0.0
      assert result.output_cost == 0.0
      assert result.cache_read_cost == 0.0
      assert result.cache_write_cost == 0.0
      assert result.total_cost == 0.0
    end

    test "all tokens nil with cost map returns all nil costs" do
      usage = %Usage{}
      result = Usage.calculate_cost(usage, @full_cost_map)

      assert result.input_cost == nil
      assert result.output_cost == nil
      assert result.cache_read_cost == nil
      assert result.cache_write_cost == nil
      assert result.total_cost == nil
    end
  end

  describe "serialization round-trip with cost fields" do
    test "round-trips cost fields through JSON" do
      original = %Usage{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 100_000,
        input_cost: 3.0,
        output_cost: 7.5,
        cache_read_cost: 0.06,
        cache_write_cost: 0.375,
        total_cost: 10.935
      }

      decoded = original |> Decoder.encode() |> Decoder.decode()

      assert decoded.input_cost == 3.0
      assert decoded.output_cost == 7.5
      assert decoded.cache_read_cost == 0.06
      assert decoded.cache_write_cost == 0.375
      assert decoded.total_cost == 10.935
    end

    test "compacts nil cost fields" do
      usage = %Usage{input_tokens: 100, output_tokens: 50}
      map = Serializable.to_map(usage)

      refute Map.has_key?(map, "input_cost")
      refute Map.has_key?(map, "output_cost")
      refute Map.has_key?(map, "cache_read_cost")
      refute Map.has_key?(map, "cache_write_cost")
      refute Map.has_key?(map, "total_cost")
    end
  end
end
