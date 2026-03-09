defmodule Sycophant.EmbeddingParamsTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.Serializable

  describe "Zoi validation" do
    test "defaults embedding_types to [:float] and truncate to :none" do
      assert {:ok, params} = Zoi.parse(EmbeddingParams.t(), %{})
      assert params.embedding_types == [:float]
      assert params.truncate == :none
      assert params.dimensions == nil
      assert params.max_tokens == nil
    end

    test "validates dimensions is positive" do
      assert {:error, _} = Zoi.parse(EmbeddingParams.t(), %{dimensions: 0})
      assert {:ok, params} = Zoi.parse(EmbeddingParams.t(), %{dimensions: 512})
      assert params.dimensions == 512
    end

    test "validates embedding_types enum values" do
      assert {:ok, params} = Zoi.parse(EmbeddingParams.t(), %{embedding_types: [:float, :int8]})
      assert params.embedding_types == [:float, :int8]
      assert {:error, _} = Zoi.parse(EmbeddingParams.t(), %{embedding_types: [:invalid]})
    end

    test "validates truncate enum" do
      assert {:ok, params} = Zoi.parse(EmbeddingParams.t(), %{truncate: :left})
      assert params.truncate == :left
      assert {:error, _} = Zoi.parse(EmbeddingParams.t(), %{truncate: :invalid})
    end

    test "validates max_tokens is positive" do
      assert {:error, _} = Zoi.parse(EmbeddingParams.t(), %{max_tokens: 0})
      assert {:ok, params} = Zoi.parse(EmbeddingParams.t(), %{max_tokens: 8192})
      assert params.max_tokens == 8192
    end

    test "accepts all params together" do
      input = %{
        dimensions: 1536,
        embedding_types: [:float, :int8, :uint8],
        truncate: :right,
        max_tokens: 128_000
      }

      assert {:ok, %EmbeddingParams{} = params} = Zoi.parse(EmbeddingParams.t(), input)
      assert params.dimensions == 1536
      assert params.embedding_types == [:float, :int8, :uint8]
      assert params.truncate == :right
      assert params.max_tokens == 128_000
    end
  end

  describe "serialization round-trip" do
    test "serializes and deserializes" do
      params = %EmbeddingParams{
        dimensions: 1536,
        embedding_types: [:float, :int8],
        truncate: :right,
        max_tokens: 128_000
      }

      map = Serializable.to_map(params)
      assert map["__type__"] == "EmbeddingParams"
      assert map["dimensions"] == 1536
      assert map["embedding_types"] == ["float", "int8"]
      assert map["truncate"] == "right"
      assert map["max_tokens"] == 128_000

      restored = EmbeddingParams.from_map(map)
      assert restored.dimensions == 1536
      assert restored.embedding_types == [:float, :int8]
      assert restored.truncate == :right
      assert restored.max_tokens == 128_000
    end

    test "serializes with defaults and omits nil fields" do
      params = %EmbeddingParams{
        embedding_types: [:float],
        truncate: :none
      }

      map = Serializable.to_map(params)
      assert map["__type__"] == "EmbeddingParams"
      assert map["embedding_types"] == ["float"]
      assert map["truncate"] == "none"
      refute Map.has_key?(map, "dimensions")
      refute Map.has_key?(map, "max_tokens")
    end

    test "from_map defaults embedding_types when nil" do
      restored = EmbeddingParams.from_map(%{"__type__" => "EmbeddingParams"})
      assert restored.embedding_types == [:float]
    end
  end
end
