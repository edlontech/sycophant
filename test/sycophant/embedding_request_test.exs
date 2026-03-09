defmodule Sycophant.EmbeddingRequestTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.Message.Content
  alias Sycophant.Serializable

  describe "serialization round-trip" do
    test "text-only inputs" do
      req = %EmbeddingRequest{
        inputs: ["hello", "world"],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{embedding_types: [:float], truncate: :none}
      }

      map = Serializable.to_map(req)
      assert map["__type__"] == "EmbeddingRequest"
      assert map["inputs"] == ["hello", "world"]

      restored = EmbeddingRequest.from_map(map)
      assert restored.inputs == ["hello", "world"]
      assert restored.model == req.model
    end

    test "image inputs" do
      req = %EmbeddingRequest{
        inputs: [%Content.Image{data: "base64data", media_type: "image/png"}],
        model: "amazon_bedrock:cohere.embed-v4"
      }

      map = Serializable.to_map(req)
      restored = EmbeddingRequest.from_map(map)
      assert [%Content.Image{data: "base64data"}] = restored.inputs
    end

    test "mixed inputs" do
      req = %EmbeddingRequest{
        inputs: [["caption", %Content.Image{data: "img", media_type: "image/png"}]],
        model: "amazon_bedrock:cohere.embed-v4"
      }

      map = Serializable.to_map(req)
      restored = EmbeddingRequest.from_map(map)
      assert [[text, %Content.Image{}]] = restored.inputs
      assert text == "caption"
    end

    test "provider_params are preserved" do
      req = %EmbeddingRequest{
        inputs: ["test"],
        model: "amazon_bedrock:cohere.embed-v4",
        provider_params: %{"input_type" => "search_document"}
      }

      map = Serializable.to_map(req)
      assert map["provider_params"] == %{"input_type" => "search_document"}

      restored = EmbeddingRequest.from_map(map)
      assert restored.provider_params == %{"input_type" => "search_document"}
    end

    test "empty provider_params are compacted away" do
      req = %EmbeddingRequest{
        inputs: ["test"],
        model: "amazon_bedrock:cohere.embed-v4",
        provider_params: %{}
      }

      map = Serializable.to_map(req)
      refute Map.has_key?(map, "provider_params")
    end
  end
end
