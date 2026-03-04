defmodule Sycophant.ModelResolverTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Sycophant.ModelResolver

  setup :verify_on_exit!

  defp build_model(attrs \\ %{}) do
    defaults = %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: :openai,
      provider_model_id: nil,
      base_url: nil,
      extra: %{wire: %{protocol: "openai_chat"}}
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
    test "maps openai_chat to OpenAICompletions adapter" do
      model = build_model(%{extra: %{wire: %{protocol: "openai_chat"}}})
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

    test "returns error for unsupported wire protocol" do
      model = build_model(%{extra: %{wire: %{protocol: "anthropic_messages"}}})
      provider = build_provider()

      expect(LLMDB, :provider, fn :openai -> {:ok, provider} end)

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
end
