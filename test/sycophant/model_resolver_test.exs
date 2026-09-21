defmodule Sycophant.ModelResolverTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Config
  alias Sycophant.ModelResolver

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_model(attrs \\ %{}) do
    defaults = %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: :openai,
      provider_model_id: nil,
      base_url: nil,
      extra: %{wire: %{protocol: "openai_completion"}}
    }

    struct(LLMDB.Model, Map.merge(defaults, attrs))
  end

  defp build_provider(attrs \\ %{}) do
    defaults = %{
      id: :openai,
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      env: ["OPENAI_API_KEY"]
    }

    struct(LLMDB.Provider, Map.merge(defaults, attrs))
  end

  describe "resolve/1 with string spec" do
    test "resolves a provider:model string into a normalized map" do
      model = build_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve("openai:gpt-4o")
      assert info.model_id == "gpt-4o"
      assert info.provider == :openai
      assert info.base_url == "https://api.openai.com/v1"
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAICompletions
      assert info.env_vars == ["OPENAI_API_KEY"]
      assert info.model_struct == model
      assert info.provider_struct == provider
    end

    test "returns error for unknown model string" do
      expect(LLMDB, :model, fn "unknown:model" -> {:error, :unknown_provider} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve("unknown:model")
    end
  end

  describe "resolve/1 with LLMDB.Model struct" do
    test "resolves struct directly without calling LLMDB.model/1" do
      model = build_model()
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.model_id == "gpt-4o"
      assert info.provider == :openai
    end

    test "prefers provider_model_id over id when set" do
      model = build_model(%{provider_model_id: "gpt-4o-2024-08-06"})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.model_id == "gpt-4o-2024-08-06"
    end

    test "prefers model base_url over provider base_url" do
      model = build_model(%{base_url: "https://custom.api.com/v1"})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.base_url == "https://custom.api.com/v1"
    end

    test "falls back to provider base_url when model has none" do
      model = build_model(%{base_url: nil})
      provider = build_provider(%{base_url: "https://api.openai.com/v1"})

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.base_url == "https://api.openai.com/v1"
    end
  end

  describe "wire protocol mapping" do
    test "maps openai_completion to OpenAICompletions adapter" do
      model = build_model(%{extra: %{wire: %{protocol: "openai_completion"}}})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAICompletions
    end

    test "maps openai_responses to OpenAIResponses adapter" do
      model = build_model(%{extra: %{wire: %{protocol: "openai_responses"}}})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAIResponses
    end

    test "returns error for missing wire protocol" do
      model = build_model(%{extra: %{}})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve(model)
    end

    test "returns error for nil extra" do
      model = build_model(%{extra: nil})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve(model)
    end

    test "raises for wire protocol string that is not an existing atom" do
      model = build_model(%{extra: %{wire: %{protocol: "totally_unknown_protocol"}}})

      assert_raise ArgumentError, fn ->
        ModelResolver.resolve(model)
      end
    end

    test "falls back to app config when model has no wire protocol" do
      model = build_model(%{extra: %{}, provider: :openrouter})
      provider = build_provider(%{id: :openrouter, base_url: "https://openrouter.ai/api/v1"})

      expect(Config, :wire_protocol_defaults, fn -> %{openrouter: %{chat: :openai_responses}} end)
      expect(LLMDB, :provider, fn :openrouter -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAIResponses
    end

    test "falls back to app config when model extra is nil" do
      model = build_model(%{extra: nil, provider: :openrouter})
      provider = build_provider(%{id: :openrouter, base_url: "https://openrouter.ai/api/v1"})

      expect(Config, :wire_protocol_defaults, fn -> %{openrouter: %{chat: :openai_responses}} end)
      expect(LLMDB, :provider, fn :openrouter -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAIResponses
    end

    test "model-level protocol takes priority over config default" do
      model =
        build_model(%{
          extra: %{wire: %{protocol: "openai_completion"}},
          provider: :openrouter
        })

      provider = build_provider(%{id: :openrouter, base_url: "https://openrouter.ai/api/v1"})

      stub(Config, :wire_protocol_defaults, fn -> %{openrouter: %{chat: :openai_responses}} end)
      expect(LLMDB, :provider, fn :openrouter -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve(model)
      assert info.wire_adapter == Sycophant.WireProtocol.OpenAICompletions
    end

    test "returns error when neither model nor config provides protocol" do
      model = build_model(%{extra: %{}, provider: :unknown_provider})
      provider = build_provider(%{id: :unknown_provider})

      expect(LLMDB, :provider, fn :unknown_provider -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve(model)
    end

    test "returns error when config provides unsupported protocol" do
      model = build_model(%{extra: %{}, provider: :badprovider})
      provider = build_provider(%{id: :badprovider})

      expect(Config, :wire_protocol_defaults, fn ->
        %{badprovider: %{chat: :unsupported_protocol}}
      end)

      expect(LLMDB, :provider, fn :badprovider -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Unknown.Unknown{}} =
               ModelResolver.resolve(model)
    end
  end

  describe "resolve/1 with invalid input" do
    test "returns error for nil" do
      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve(nil)
    end

    test "returns error for non-string, non-struct input" do
      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve(42)
    end
  end

  describe "resolve_embedding/1" do
    test "resolves embedding model with adapter from config defaults" do
      model =
        build_model(%{
          provider: :amazon_bedrock,
          modalities: %{input: [:text], output: [:embedding]},
          extra: %{}
        })

      provider =
        build_provider(%{
          id: :amazon_bedrock,
          base_url: "https://bedrock-runtime.us-east-1.amazonaws.com"
        })

      expect(LLMDB, :model, fn "amazon_bedrock:cohere.embed-v4" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      expect(Config, :wire_protocol_defaults, fn ->
        %{amazon_bedrock: %{chat: :bedrock_converse, embedding: :bedrock_embed}}
      end)

      assert {:ok, info} = ModelResolver.resolve_embedding("amazon_bedrock:cohere.embed-v4")
      assert info.wire_adapter == Sycophant.EmbeddingWireProtocol.BedrockEmbed
    end

    test "returns error for non-embedding model" do
      model =
        build_model(%{
          modalities: %{input: [:text], output: [:text]},
          extra: %{wire: %{protocol: "openai_completion"}}
        })

      expect(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)

      assert {:error, error} = ModelResolver.resolve_embedding("openai:gpt-4o")
      assert Exception.message(error) =~ "embeddings"
    end

    test "returns error for nil" do
      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve_embedding(nil)
    end

    test "returns error for unknown model string" do
      expect(LLMDB, :model, fn "fake:model" -> {:error, :not_found} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve_embedding("fake:model")
    end

    test "returns error for provider without embedding adapter" do
      model =
        build_model(%{
          provider: :google,
          modalities: %{input: [:text], output: [:embedding]},
          extra: %{}
        })

      provider = build_provider(%{id: :google})

      expect(LLMDB, :model, fn "google:text-embedding" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :google -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve_embedding("google:text-embedding")
    end

    test "model-level embedding_protocol takes priority over config default" do
      model =
        build_model(%{
          provider: :amazon_bedrock,
          modalities: %{input: [:text], output: [:embedding]},
          extra: %{wire: %{embedding_protocol: "openai_embed"}}
        })

      provider =
        build_provider(%{
          id: :amazon_bedrock,
          base_url: "https://bedrock-runtime.us-east-1.amazonaws.com"
        })

      stub(Config, :wire_protocol_defaults, fn ->
        %{amazon_bedrock: %{embedding: :bedrock_embed}}
      end)

      expect(LLMDB, :model, fn "amazon_bedrock:embed-model" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :amazon_bedrock -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve_embedding("amazon_bedrock:embed-model")
      assert info.wire_adapter == Sycophant.EmbeddingWireProtocol.OpenAIEmbed
    end

    test "falls back to config default when model has no embedding_protocol" do
      model =
        build_model(%{
          provider: :azure,
          modalities: %{input: [:text], output: [:embedding]},
          extra: %{}
        })

      provider =
        build_provider(%{
          id: :azure,
          base_url: "https://my-resource.openai.azure.com"
        })

      expect(LLMDB, :model, fn "azure:text-embedding" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :azure -> {:ok, provider} end)

      expect(Config, :wire_protocol_defaults, fn ->
        %{azure: %{embedding: :openai_embed}}
      end)

      assert {:ok, info} = ModelResolver.resolve_embedding("azure:text-embedding")
      assert info.wire_adapter == Sycophant.EmbeddingWireProtocol.OpenAIEmbed
    end
  end

  describe "resolve_evaluation/1" do
    test "resolves an evaluation-only model into a normalized map" do
      model =
        build_model(%{
          id: "jev-latest",
          provider: :typesafe,
          extra: nil,
          capabilities: %{chat: false, evaluate: true, embeddings: false},
          execution: %{evaluate: %{wire_protocol: "typesafe_systemone"}}
        })

      provider =
        build_provider(%{
          id: :typesafe,
          base_url: "https://api.typesafe.ai",
          env: ["TYPESAFE_API_KEY"]
        })

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      assert {:ok, info} = ModelResolver.resolve_evaluation("typesafe:jev-latest")
      assert info.wire_adapter == Sycophant.EvaluationWireProtocol.TypesafeSystemone
      assert info.base_url == "https://api.typesafe.ai"
      assert info.model_id == "jev-latest"
      assert info.provider == :typesafe
    end

    test "returns error for a model that does not support evaluation" do
      model = build_model(%{capabilities: %{chat: true, evaluate: false, embeddings: false}})

      expect(LLMDB, :model, fn "openai:gpt-4o-mini" -> {:ok, model} end)

      assert {:error, error} = ModelResolver.resolve_evaluation("openai:gpt-4o-mini")
      assert Exception.message(error) =~ "model does not support evaluation"
    end

    test "returns an unsupported protocol error, without raising, for an unmapped protocol atom" do
      model =
        build_model(%{
          provider: :cloudflare_workers_ai,
          extra: nil,
          capabilities: %{chat: false, evaluate: true, embeddings: false},
          execution: %{evaluate: %{wire_protocol: "cloudflare_ai_run"}}
        })

      provider = build_provider(%{id: :cloudflare_workers_ai})

      expect(LLMDB, :model, fn "cloudflare_workers_ai:typesafe/jev" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :cloudflare_workers_ai -> {:ok, provider} end)

      assert {:error, %Sycophant.Error.Unknown.Unknown{} = error} =
               ModelResolver.resolve_evaluation("cloudflare_workers_ai:typesafe/jev")

      assert Exception.message(error) =~ "Unsupported evaluate protocol"
    end

    test "returns an error tuple, without raising, when the model has no execution.evaluate entry" do
      model =
        build_model(%{
          provider: :vercel,
          extra: nil,
          capabilities: %{chat: false, evaluate: true, embeddings: false},
          execution: nil
        })

      provider = build_provider(%{id: :vercel})

      expect(LLMDB, :model, fn "vercel:typesafe-ai/jev" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :vercel -> {:ok, provider} end)

      assert {:error, _error} = ModelResolver.resolve_evaluation("vercel:typesafe-ai/jev")
    end

    test "returns error for nil" do
      assert {:error, %Sycophant.Error.Invalid.MissingModel{}} =
               ModelResolver.resolve_evaluation(nil)
    end
  end

  describe "resolve_evaluation/1 against the real LLMDB catalog (no stubs)" do
    test "resolves typesafe:jev-latest" do
      assert {:ok, info} = ModelResolver.resolve_evaluation("typesafe:jev-latest")
      assert info.provider == :typesafe
      assert info.base_url == "https://api.typesafe.ai"
      assert info.wire_adapter == Sycophant.EvaluationWireProtocol.TypesafeSystemone
    end

    test "resolves openrouter:typesafe/jev-1.13" do
      assert {:ok, info} = ModelResolver.resolve_evaluation("openrouter:typesafe/jev-1.13")
      assert info.wire_adapter == Sycophant.EvaluationWireProtocol.OpenRouterDecisions
      assert info.base_url == "https://openrouter.ai"
      assert info.model_id == "typesafe/jev-1.13"
    end

    test "resolves openrouter:~typesafe/jev-latest" do
      assert {:ok, info} = ModelResolver.resolve_evaluation("openrouter:~typesafe/jev-latest")
      assert info.wire_adapter == Sycophant.EvaluationWireProtocol.OpenRouterDecisions
    end
  end

  describe "resolve/1 rejects evaluation-only models" do
    test "returns an InvalidParams error pointing at evaluate/4" do
      model =
        build_model(%{
          provider: :typesafe,
          extra: nil,
          capabilities: %{chat: false, evaluate: true, embeddings: false}
        })

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)

      assert {:error, error} = ModelResolver.resolve("typesafe:jev-latest")
      assert Exception.message(error) =~ "Sycophant.evaluate/4"
    end

    test "still resolves chat models without capabilities metadata" do
      model = build_model(%{capabilities: nil})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      assert {:ok, _info} = ModelResolver.resolve(model)
    end
  end
end
