defmodule Sycophant.LocalProviderTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Message
  alias Sycophant.Pipeline
  alias Sycophant.Response

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_local_model(attrs \\ %{}) do
    defaults = %{
      id: "llama3",
      name: "Llama 3",
      provider: :ollama,
      provider_model_id: nil,
      base_url: nil,
      extra: %{wire: %{protocol: "openai_chat"}}
    }

    struct(LLMDB.Model, Map.merge(defaults, attrs))
  end

  defp build_local_provider(attrs) do
    defaults = %{
      id: :ollama,
      name: "Ollama",
      base_url: "http://localhost:11434/v1",
      env: [],
      extra: %{auth: :none}
    }

    struct(LLMDB.Provider, Map.merge(defaults, attrs))
  end

  defp openai_chat_response(text \\ "Hello from local!") do
    %{
      "id" => "chatcmpl-local-123",
      "object" => "chat.completion",
      "model" => "llama3",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 8, "completion_tokens" => 12, "total_tokens" => 20}
    }
  end

  defp stub_local_provider(provider_attrs \\ %{}) do
    model = build_local_model()
    provider = build_local_provider(provider_attrs)

    stub(LLMDB, :model, fn "ollama:llama3" -> {:ok, model} end)
    stub(LLMDB, :provider, fn :ollama -> {:ok, provider} end)

    {model, provider}
  end

  describe "local provider with auth: :none" do
    test "completes pipeline without credentials" do
      stub_local_provider()

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        assert opts[:auth_middlewares] == []
        assert opts[:base_url] == "http://localhost:11434/v1"
        assert opts[:path] == "/chat/completions"

        {:ok, openai_chat_response()}
      end)

      assert {:ok, %Response{} = response} =
               Pipeline.call([Message.user("Hi")], model: "ollama:llama3")

      assert response.text == "Hello from local!"
      assert response.finish_reason == :stop
      assert response.tool_calls == []
    end

    test "decodes usage from OpenAI-compatible response" do
      stub_local_provider()

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok, openai_chat_response()}
      end)

      assert {:ok, %Response{usage: usage}} =
               Pipeline.call([Message.user("Hi")], model: "ollama:llama3")

      assert usage.input_tokens == 8
      assert usage.output_tokens == 12
    end

    test "populates context with messages for multi-turn" do
      stub_local_provider()

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok, openai_chat_response()}
      end)

      assert {:ok, %Response{context: context}} =
               Pipeline.call([Message.user("Hi")], model: "ollama:llama3")

      assert length(context.messages) == 2
      assert Enum.at(context.messages, 0).role == :user
      assert Enum.at(context.messages, 1).role == :assistant
      assert Enum.at(context.messages, 1).content == "Hello from local!"
    end

    test "sends model ID and messages in encoded payload" do
      stub_local_provider()

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        assert payload["model"] == "llama3"
        assert is_list(payload["messages"])
        assert hd(payload["messages"])["role"] == "user"

        {:ok, openai_chat_response()}
      end)

      assert {:ok, _} = Pipeline.call([Message.user("Hi")], model: "ollama:llama3")
    end
  end

  describe "local provider with auth: :optional and credentials provided" do
    test "passes bearer auth when credentials are given" do
      stub_local_provider(%{extra: %{auth: :optional}})

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        [{Tesla.Middleware.Headers, headers}] = opts[:auth_middlewares]
        assert {"authorization", "Bearer sk-local"} in headers

        {:ok, openai_chat_response()}
      end)

      opts = [model: "ollama:llama3", credentials: %{api_key: "sk-local"}]

      assert {:ok, %Response{text: "Hello from local!"}} =
               Pipeline.call([Message.user("Hi")], opts)
    end

    test "works without credentials when auth is optional" do
      stub_local_provider(%{extra: %{auth: :optional}})

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        assert opts[:auth_middlewares] == []
        {:ok, openai_chat_response()}
      end)

      assert {:ok, %Response{}} =
               Pipeline.call([Message.user("Hi")], model: "ollama:llama3")
    end
  end
end
