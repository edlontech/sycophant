defmodule SycophantTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Message
  alias Sycophant.Response

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_model(attrs \\ %{}) do
    defaults = %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: :openai,
      provider_model_id: nil,
      base_url: nil,
      extra: %{wire: %{protocol: "openai_responses"}}
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

  describe "generate_text/2" do
    test "delegates to Pipeline and returns Response" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Hello!"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      assert {:ok, %Response{text: "Hello!"}} =
               Sycophant.generate_text([Message.user("Hi")], model: "openai:gpt-4o")
    end
  end
end
