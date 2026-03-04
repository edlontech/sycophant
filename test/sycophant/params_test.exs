defmodule Sycophant.ParamsTest do
  use ExUnit.Case, async: true

  alias Sycophant.Params

  describe "Zoi validation via Params.t()" do
    test "accepts valid params" do
      assert {:ok, %Params{temperature: 0.7, max_tokens: 4096}} =
               Zoi.parse(Params.t(), %{temperature: 0.7, max_tokens: 4096})
    end

    test "accepts empty map (all fields optional)" do
      assert {:ok, %Params{}} = Zoi.parse(Params.t(), %{})
    end

    test "rejects temperature out of range" do
      assert {:error, _} = Zoi.parse(Params.t(), %{temperature: 3.0})
    end

    test "rejects negative max_tokens" do
      assert {:error, _} = Zoi.parse(Params.t(), %{max_tokens: -1})
    end

    test "validates reasoning enum" do
      assert {:ok, %Params{reasoning: :medium}} =
               Zoi.parse(Params.t(), %{reasoning: :medium})

      assert {:error, _} = Zoi.parse(Params.t(), %{reasoning: :extreme})
    end

    test "validates reasoning_summary enum" do
      assert {:ok, %Params{reasoning_summary: :concise}} =
               Zoi.parse(Params.t(), %{reasoning_summary: :concise})
    end

    test "validates frequency_penalty range" do
      assert {:ok, %Params{frequency_penalty: -1.5}} =
               Zoi.parse(Params.t(), %{frequency_penalty: -1.5})

      assert {:error, _} = Zoi.parse(Params.t(), %{frequency_penalty: 3.0})
    end

    test "validates stop as list of strings" do
      assert {:ok, %Params{stop: ["END", "STOP"]}} =
               Zoi.parse(Params.t(), %{stop: ["END", "STOP"]})
    end

    test "accepts all params together" do
      input = %{
        temperature: 1.0,
        max_tokens: 2048,
        top_p: 0.9,
        top_k: 40,
        stop: ["END"],
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.5,
        reasoning: :high,
        reasoning_summary: :detailed,
        parallel_tool_calls: true,
        cache_key: "my-cache",
        cache_retention: 3600,
        safety_identifier: "default",
        service_tier: "auto"
      }

      assert {:ok, %Params{} = params} = Zoi.parse(Params.t(), input)
      assert params.temperature == 1.0
      assert params.reasoning == :high
      assert params.parallel_tool_calls == true
    end
  end
end
