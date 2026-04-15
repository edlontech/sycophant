defmodule Sycophant.ParamDefsTest do
  use ExUnit.Case, async: true

  alias Sycophant.ParamDefs

  describe "shared/0" do
    test "returns a map with all 11 expected keys" do
      shared = ParamDefs.shared()

      expected_keys = [
        :temperature,
        :max_tokens,
        :top_p,
        :top_k,
        :stop,
        :reasoning_effort,
        :reasoning_budget,
        :reasoning_summary,
        :service_tier,
        :tool_choice,
        :parallel_tool_calls
      ]

      assert map_size(shared) == 11
      for key <- expected_keys, do: assert(Map.has_key?(shared, key), "missing key: #{key}")
    end
  end

  describe "composing into Zoi.object schema" do
    test "validates valid params" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7, max_tokens: 100})
      assert result.temperature == 0.7
      assert result.max_tokens == 100
    end

    test "accepts empty map since all params are optional" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:ok, result} = Zoi.parse(schema, %{})
      assert map_size(result) == 0
    end

    test "strips unrecognized keys" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.5, unknown_key: "value"})
      assert result.temperature == 0.5
      refute Map.has_key?(result, :unknown_key)
    end

    test "rejects temperature out of range" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:error, _} = Zoi.parse(schema, %{temperature: 3.0})
    end

    test "rejects negative max_tokens" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:error, _} = Zoi.parse(schema, %{max_tokens: -1})
    end

    test "rejects top_p out of range" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:error, _} = Zoi.parse(schema, %{top_p: 1.5})
    end

    test "rejects invalid reasoning_effort enum value" do
      schema = Zoi.object(ParamDefs.shared())

      assert {:error, _} = Zoi.parse(schema, %{reasoning_effort: :extreme})
    end

    test "accepts valid reasoning_effort enum values" do
      schema = Zoi.object(ParamDefs.shared())

      for level <- [:low, :medium, :high] do
        assert {:ok, result} = Zoi.parse(schema, %{reasoning_effort: level})
        assert result.reasoning_effort == level
      end
    end

    test "composes with wire-specific extras via Map.merge" do
      extras = %{
        seed: Zoi.integer(description: "Random seed") |> Zoi.optional()
      }

      schema = Zoi.object(Map.merge(ParamDefs.shared(), extras))

      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.5, seed: 42})
      assert result.temperature == 0.5
      assert result.seed == 42
    end
  end
end
