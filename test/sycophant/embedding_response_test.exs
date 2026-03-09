defmodule Sycophant.EmbeddingResponseTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingResponse
  alias Sycophant.Serializable
  alias Sycophant.Usage

  describe "serialization round-trip" do
    test "single embedding type" do
      resp = %EmbeddingResponse{
        embeddings: %{float: [[0.1, 0.2], [0.3, 0.4]]},
        model: "cohere.embed-v4",
        usage: %Usage{input_tokens: 10}
      }

      map = Serializable.to_map(resp)
      assert map["__type__"] == "EmbeddingResponse"
      assert map["embeddings"]["float"] == [[0.1, 0.2], [0.3, 0.4]]

      restored = EmbeddingResponse.from_map(map)
      assert restored.embeddings == %{float: [[0.1, 0.2], [0.3, 0.4]]}
    end

    test "multiple embedding types" do
      resp = %EmbeddingResponse{
        embeddings: %{float: [[0.1, 0.2]], int8: [[-12, 45]]},
        model: "cohere.embed-v4"
      }

      map = Serializable.to_map(resp)
      restored = EmbeddingResponse.from_map(map)
      assert restored.embeddings.float == [[0.1, 0.2]]
      assert restored.embeddings.int8 == [[-12, 45]]
    end

    test "usage is preserved through round-trip" do
      resp = %EmbeddingResponse{
        embeddings: %{float: [[1.0]]},
        model: "cohere.embed-v4",
        usage: %Usage{input_tokens: 10, output_tokens: 0}
      }

      map = Serializable.to_map(resp)
      restored = EmbeddingResponse.from_map(map)
      assert restored.usage.input_tokens == 10
    end

    test "nil usage and raw are compacted" do
      resp = %EmbeddingResponse{
        embeddings: %{float: [[1.0]]},
        model: "cohere.embed-v4"
      }

      map = Serializable.to_map(resp)
      refute Map.has_key?(map, "usage")
      refute Map.has_key?(map, "raw")
    end
  end
end
