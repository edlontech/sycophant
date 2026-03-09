defmodule Sycophant.EmbeddingWireProtocol.BedrockEmbedTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingWireProtocol.BedrockEmbed
  alias Sycophant.Message.Content

  describe "request_path/1" do
    test "builds invoke path with encoded model" do
      req = %EmbeddingRequest{inputs: ["hi"], model: "cohere.embed-v4:0"}
      assert BedrockEmbed.request_path(req) == "/model/cohere.embed-v4%3A0/invoke"
    end
  end

  describe "encode_request/1 input classification" do
    test "text-only uses texts key" do
      req = %EmbeddingRequest{inputs: ["hello", "world"], model: "cohere.embed-v4"}
      assert {:ok, payload} = BedrockEmbed.encode_request(req)
      assert payload["texts"] == ["hello", "world"]
      refute Map.has_key?(payload, "images")
      refute Map.has_key?(payload, "inputs")
    end

    test "image-only uses images key" do
      img = %Content.Image{data: "abc123", media_type: "image/png"}
      req = %EmbeddingRequest{inputs: [img], model: "cohere.embed-v4"}
      assert {:ok, payload} = BedrockEmbed.encode_request(req)
      assert ["data:image/png;base64,abc123"] = payload["images"]
    end

    test "mixed inputs uses inputs key" do
      mixed = ["caption", %Content.Image{data: "img", media_type: "image/jpeg"}]
      req = %EmbeddingRequest{inputs: [mixed], model: "cohere.embed-v4"}
      assert {:ok, payload} = BedrockEmbed.encode_request(req)
      assert [%{"content" => content}] = payload["inputs"]
      assert [%{"type" => "text", "text" => "caption"}, %{"type" => "image_url"}] = content
    end
  end

  describe "encode_request/1 params" do
    test "translates canonical params" do
      params = %EmbeddingParams{
        dimensions: 512,
        embedding_types: [:float, :int8],
        truncate: :right,
        max_tokens: 1000
      }

      req = %EmbeddingRequest{inputs: ["hi"], model: "m", params: params}
      assert {:ok, payload} = BedrockEmbed.encode_request(req)
      assert payload["output_dimension"] == 512
      assert payload["embedding_types"] == ["float", "int8"]
      assert payload["truncate"] == "RIGHT"
      assert payload["max_tokens"] == 1000
    end

    test "merges provider_params" do
      req = %EmbeddingRequest{
        inputs: ["hi"],
        model: "m",
        provider_params: %{"input_type" => "search_document"}
      }

      assert {:ok, payload} = BedrockEmbed.encode_request(req)
      assert payload["input_type"] == "search_document"
    end
  end

  describe "decode_response/2" do
    test "normalizes flat list response to keyed map" do
      body = %{"embeddings" => [[0.1, 0.2], [0.3, 0.4]]}
      assert {:ok, resp} = BedrockEmbed.decode_response(body, [])
      assert resp.embeddings == %{float: [[0.1, 0.2], [0.3, 0.4]]}
    end

    test "converts string-keyed map to atom-keyed" do
      body = %{
        "embeddings" => %{
          "float" => [[0.1, 0.2]],
          "int8" => [[-12, 45]]
        }
      }

      assert {:ok, resp} = BedrockEmbed.decode_response(body, [])
      assert resp.embeddings.float == [[0.1, 0.2]]
      assert resp.embeddings.int8 == [[-12, 45]]
    end

    test "extracts usage from response header" do
      body = %{"embeddings" => [[0.1]]}
      headers = [{"x-amzn-bedrock-input-token-count", "42"}]

      assert {:ok, resp} = BedrockEmbed.decode_response(body, headers)
      assert resp.usage.input_tokens == 42
    end

    test "falls back to body meta for usage" do
      body = %{
        "embeddings" => [[0.1]],
        "meta" => %{"billed_units" => %{"input_tokens" => 99}}
      }

      assert {:ok, resp} = BedrockEmbed.decode_response(body, [])
      assert resp.usage.input_tokens == 99
    end

    test "returns nil usage when neither header nor body has it" do
      body = %{"embeddings" => [[0.1]]}
      assert {:ok, resp} = BedrockEmbed.decode_response(body, [])
      assert resp.usage == nil
    end

    test "returns error for invalid body" do
      assert {:error, _} = BedrockEmbed.decode_response(%{"unexpected" => true}, [])
    end
  end
end
