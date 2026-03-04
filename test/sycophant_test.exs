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

  describe "generate_text/2 continuation" do
    test "accepts Response and Message, re-enters pipeline with accumulated messages" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "id" => "resp-1",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Hello!"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      {:ok, resp1} = Sycophant.generate_text([Message.user("Hi")], model: "openai:gpt-4o")

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        input = payload["input"]
        assert length(input) == 3

        {:ok,
         %{
           "id" => "resp-2",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "World!"}]
             }
           ],
           "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
         }}
      end)

      {:ok, resp2} = Sycophant.generate_text(resp1, Message.user("Continue"))
      assert resp2.text == "World!"
      assert length(Response.messages(resp2)) == 4
    end

    test "carries params from original call through continuation" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "id" => "resp-1",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
         }}
      end)

      {:ok, resp} =
        Sycophant.generate_text([Message.user("Hi")],
          model: "openai:gpt-4o",
          temperature: 0.7
        )

      assert resp.context.params.temperature == 0.7

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        assert payload["temperature"] == 0.7

        {:ok,
         %{
           "id" => "resp-2",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
         }}
      end)

      assert {:ok, _} = Sycophant.generate_text(resp, Message.user("More"))
    end
  end

  describe "generate_object/3" do
    test "returns validated object from JSON response" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": "Alice", "age": 30})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:ok, %Response{object: %{name: "Alice", age: 30}}} =
               Sycophant.generate_object([Message.user("Give me a person")], schema,
                 model: "openai:gpt-4o"
               )
    end

    test "returns error when response fails validation" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": 123})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               Sycophant.generate_object([Message.user("Give me a person")], schema,
                 model: "openai:gpt-4o"
               )
    end

    test "skips validation with validate: false" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": "Alice", "age": 30})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:ok, %Response{object: %{"name" => "Alice", "age" => 30}}} =
               Sycophant.generate_object([Message.user("Give me a person")], schema,
                 model: "openai:gpt-4o",
                 validate: false
               )
    end
  end

  describe "generate_object/2 continuation" do
    test "carries response_schema through context" do
      model = build_model()
      provider = build_provider()
      counter = :counters.new(1, [:atomics])

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        json =
          case count do
            1 -> ~s({"name": "Alice", "age": 30})
            2 -> ~s({"name": "Bob", "age": 25})
          end

        {:ok,
         %{
           "id" => "resp-#{count}",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => json}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      {:ok, resp1} =
        Sycophant.generate_object([Message.user("Give me a person")], schema,
          model: "openai:gpt-4o"
        )

      assert resp1.object == %{name: "Alice", age: 30}

      {:ok, resp2} = Sycophant.generate_object(resp1, Message.user("Give me another"))
      assert resp2.object == %{name: "Bob", age: 25}
    end
  end
end
