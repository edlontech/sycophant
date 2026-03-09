defmodule Sycophant.EmbeddingPipelineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingPipeline
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Error

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_embed_model(attrs \\ %{}) do
    defaults = %{
      id: "cohere.embed-v4",
      provider: :amazon_bedrock,
      provider_model_id: "cohere.embed-v4:0",
      modalities: %{input: [:text], output: [:embedding]},
      capabilities: %{
        embeddings: %{default_dimensions: 1536, max_dimensions: 1536, min_dimensions: 256}
      },
      extra: %{},
      base_url: nil
    }

    struct(LLMDB.Model, Map.merge(defaults, attrs))
  end

  defp build_provider(attrs \\ %{}) do
    defaults = %{
      id: :amazon_bedrock,
      name: "Amazon Bedrock",
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      env: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    }

    struct(LLMDB.Provider, Map.merge(defaults, attrs))
  end

  describe "call/2" do
    test "returns error for nil model" do
      request = %EmbeddingRequest{inputs: ["hello"], model: nil}
      assert {:error, %Error.Invalid.MissingModel{}} = EmbeddingPipeline.call(request)
    end

    test "returns error for non-embedding model" do
      model = build_embed_model(%{modalities: %{input: [:text], output: [:text]}})

      expect(LLMDB, :model, fn "amazon_bedrock:anthropic.claude" -> {:ok, model} end)

      request = %EmbeddingRequest{inputs: ["hello"], model: "amazon_bedrock:anthropic.claude"}
      assert {:error, error} = EmbeddingPipeline.call(request)
      assert Exception.message(error) =~ "embeddings"
    end

    test "returns error for unknown model spec" do
      expect(LLMDB, :model, fn "fake:model" -> {:error, :not_found} end)

      request = %EmbeddingRequest{inputs: ["hello"], model: "fake:model"}
      assert {:error, %Error.Invalid.MissingModel{}} = EmbeddingPipeline.call(request)
    end

    test "returns error for provider without embedding adapter" do
      model = build_embed_model(%{provider: :openai})
      provider = build_provider(%{id: :openai, base_url: "https://api.openai.com/v1"})

      expect(LLMDB, :model, fn "openai:text-embedding" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      request = %EmbeddingRequest{inputs: ["hello"], model: "openai:text-embedding"}
      assert {:error, _} = EmbeddingPipeline.call(request)
    end

    test "full pipeline with mocked transport" do
      model = build_embed_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {%{"embeddings" => [[0.1, 0.2, 0.3]]}, [{"x-amzn-bedrock-input-token-count", "5"}]}}
      end)

      request = %EmbeddingRequest{
        inputs: ["hello world"],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{embedding_types: [:float], truncate: :none}
      }

      assert {:ok, %EmbeddingResponse{} = response} =
               EmbeddingPipeline.call(request, credentials: %{region: "us-east-1"})

      assert response.embeddings == %{float: [[0.1, 0.2, 0.3]]}
      assert response.model == "cohere.embed-v4:0"
    end

    test "propagates transport errors" do
      model = build_embed_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 500, body: "boom")}
      end)

      request = %EmbeddingRequest{
        inputs: ["hello"],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{embedding_types: [:float], truncate: :none}
      }

      assert {:error, %Error.Provider.ServerError{}} =
               EmbeddingPipeline.call(request, credentials: %{region: "us-east-1"})
    end

    test "validates params from opts when request params is nil" do
      model = build_embed_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {%{"embeddings" => [[0.1, 0.2]]}, []}}
      end)

      request = %EmbeddingRequest{
        inputs: ["hello"],
        model: "amazon_bedrock:cohere.embed-v4"
      }

      assert {:ok, %EmbeddingResponse{}} =
               EmbeddingPipeline.call(request,
                 credentials: %{region: "us-east-1"},
                 dimensions: 256
               )
    end
  end

  describe "call/2 telemetry" do
    setup do
      test_pid = self()
      handler_id = "embedding-pipeline-telemetry-#{inspect(test_pid)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:sycophant, :embedding, :start],
          [:sycophant, :embedding, :stop],
          [:sycophant, :embedding, :error]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits start and stop events on success" do
      model = build_embed_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {%{"embeddings" => [[0.1, 0.2, 0.3]]}, [{"x-amzn-bedrock-input-token-count", "5"}]}}
      end)

      request = %EmbeddingRequest{
        inputs: ["hello"],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{embedding_types: [:float], truncate: :none}
      }

      assert {:ok, _} = EmbeddingPipeline.call(request, credentials: %{region: "us-east-1"})

      assert_received {:telemetry_event, [:sycophant, :embedding, :start], _, start_meta}
      assert start_meta.provider == :amazon_bedrock
      assert start_meta.input_count == 1

      assert_received {:telemetry_event, [:sycophant, :embedding, :stop], _, _}
    end

    test "emits start and error events on transport failure" do
      model = build_embed_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 500, body: "boom")}
      end)

      request = %EmbeddingRequest{
        inputs: ["hello"],
        model: "amazon_bedrock:cohere.embed-v4",
        params: %EmbeddingParams{embedding_types: [:float], truncate: :none}
      }

      assert {:error, _} = EmbeddingPipeline.call(request, credentials: %{region: "us-east-1"})

      assert_received {:telemetry_event, [:sycophant, :embedding, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :embedding, :error], _, error_meta}
      assert error_meta.error_class == :provider
    end

    test "does not emit telemetry when model resolution fails" do
      request = %EmbeddingRequest{inputs: ["hello"], model: nil}
      assert {:error, _} = EmbeddingPipeline.call(request)

      refute_received {:telemetry_event, [:sycophant, :embedding, :start], _, _}
    end
  end
end
