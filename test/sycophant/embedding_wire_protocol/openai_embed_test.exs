defmodule Sycophant.EmbeddingWireProtocol.OpenAIEmbedTest do
  use ExUnit.Case, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingWireProtocol.OpenAIEmbed

  describe "request_path/1" do
    test "returns /embeddings" do
      req = %EmbeddingRequest{inputs: ["hi"], model: "text-embedding-3-large"}
      assert OpenAIEmbed.request_path(req) == "/embeddings"
    end
  end

  describe "encode_request/1" do
    test "produces payload with model and input" do
      req = %EmbeddingRequest{inputs: ["hello", "world"], model: "text-embedding-3-large"}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      assert payload["model"] == "text-embedding-3-large"
      assert payload["input"] == ["hello", "world"]
    end

    test "includes dimensions when set in params" do
      params = %EmbeddingParams{dimensions: 512}
      req = %EmbeddingRequest{inputs: ["hi"], model: "m", params: params}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      assert payload["dimensions"] == 512
    end

    test "omits dimensions when params is nil" do
      req = %EmbeddingRequest{inputs: ["hi"], model: "m"}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      refute Map.has_key?(payload, "dimensions")
    end

    test "includes encoding_format float from embedding_types" do
      params = %EmbeddingParams{embedding_types: [:float]}
      req = %EmbeddingRequest{inputs: ["hi"], model: "m", params: params}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      assert payload["encoding_format"] == "float"
    end

    test "includes encoding_format base64 from embedding_types" do
      params = %EmbeddingParams{embedding_types: [:base64]}
      req = %EmbeddingRequest{inputs: ["hi"], model: "m", params: params}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      assert payload["encoding_format"] == "base64"
    end

    test "omits encoding_format when no recognized type" do
      params = %EmbeddingParams{embedding_types: [:int8]}
      req = %EmbeddingRequest{inputs: ["hi"], model: "m", params: params}
      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      refute Map.has_key?(payload, "encoding_format")
    end

    test "merges provider_params" do
      req = %EmbeddingRequest{
        inputs: ["hi"],
        model: "m",
        provider_params: %{"user" => "test-user"}
      }

      assert {:ok, payload} = OpenAIEmbed.encode_request(req)
      assert payload["user"] == "test-user"
    end
  end

  describe "decode_response/2" do
    test "parses standard OpenAI embedding response" do
      body = %{
        "data" => [%{"embedding" => [0.1, 0.2, 0.3], "index" => 0}],
        "model" => "text-embedding-3-large",
        "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
      }

      assert {:ok, resp} = OpenAIEmbed.decode_response(body, [])
      assert resp.embeddings == %{float: [[0.1, 0.2, 0.3]]}
      assert resp.model == "text-embedding-3-large"
      assert resp.raw == body
    end

    test "sorts embeddings by index" do
      body = %{
        "data" => [
          %{"embedding" => [0.3, 0.4], "index" => 1},
          %{"embedding" => [0.1, 0.2], "index" => 0}
        ],
        "model" => "m"
      }

      assert {:ok, resp} = OpenAIEmbed.decode_response(body, [])
      assert resp.embeddings == %{float: [[0.1, 0.2], [0.3, 0.4]]}
    end

    test "extracts usage from prompt_tokens" do
      body = %{
        "data" => [%{"embedding" => [0.1], "index" => 0}],
        "usage" => %{"prompt_tokens" => 42, "total_tokens" => 42}
      }

      assert {:ok, resp} = OpenAIEmbed.decode_response(body, [])
      assert resp.usage.input_tokens == 42
    end

    test "returns nil usage when not present" do
      body = %{"data" => [%{"embedding" => [0.1], "index" => 0}]}
      assert {:ok, resp} = OpenAIEmbed.decode_response(body, [])
      assert resp.usage == nil
    end

    test "returns error for invalid body" do
      assert {:error, _} = OpenAIEmbed.decode_response(%{"unexpected" => true}, [])
    end
  end
end
