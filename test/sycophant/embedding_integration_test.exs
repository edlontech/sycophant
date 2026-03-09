defmodule Sycophant.EmbeddingIntegrationTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Message.Content
  alias Sycophant.Serializable.Decoder
  alias Sycophant.Usage

  describe "full serialization round-trip" do
    test "request with mixed inputs survives JSON encode/decode" do
      request = %EmbeddingRequest{
        inputs: [
          "search query text",
          %Content.Image{data: "base64img", media_type: "image/png"},
          ["caption", %Content.Image{data: "img2", media_type: "image/jpeg"}]
        ],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{
          dimensions: 512,
          embedding_types: [:float, :int8],
          truncate: :right,
          max_tokens: 1000
        },
        provider_params: %{"input_type" => "search_document"}
      }

      json = Decoder.encode(request)
      restored = Decoder.decode(json)

      assert %EmbeddingRequest{} = restored
      assert length(restored.inputs) == 3
      assert restored.model == "amazon_bedrock:cohere.embed-v4"
      assert restored.params.dimensions == 512
      assert restored.params.embedding_types == [:float, :int8]
      assert restored.provider_params["input_type"] == "search_document"
    end

    test "response survives JSON encode/decode" do
      response = %EmbeddingResponse{
        embeddings: %{float: [[0.1, 0.2], [0.3, 0.4]], int8: [[-1, 2], [3, -4]]},
        model: "cohere.embed-v4",
        usage: %Usage{input_tokens: 42},
        raw: %{"id" => "abc"}
      }

      json = Decoder.encode(response)
      restored = Decoder.decode(json)

      assert %EmbeddingResponse{} = restored
      assert restored.embeddings.float == [[0.1, 0.2], [0.3, 0.4]]
      assert restored.embeddings.int8 == [[-1, 2], [3, -4]]
      assert restored.usage.input_tokens == 42
    end
  end
end
