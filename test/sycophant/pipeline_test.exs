defmodule Sycophant.PipelineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Error
  alias Sycophant.Message
  alias Sycophant.Pipeline
  alias Sycophant.Response
  alias Sycophant.Telemetry

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

  defp stub_happy_path do
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
         "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
       }}
    end)
  end

  defp default_messages do
    [Message.user("Hi")]
  end

  defp default_opts do
    [model: "openai:gpt-4o"]
  end

  describe "call/2 happy path" do
    test "resolves model, encodes, transports, decodes and returns Response" do
      stub_happy_path()

      assert {:ok, %Response{text: "Hello!"}} =
               Pipeline.call(default_messages(), default_opts())
    end

    test "response includes usage information" do
      stub_happy_path()

      assert {:ok, %Response{usage: usage}} =
               Pipeline.call(default_messages(), default_opts())

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "passes encoded request payload to transport" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn payload, opts ->
        assert is_map(payload)
        assert payload["model"] == "gpt-4o"
        assert payload["input"] != nil
        assert opts[:base_url] == "https://api.openai.com/v1"
        assert opts[:path] == "/responses"

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

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())
    end

    test "builds auth middlewares from resolved credentials" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        auth_middlewares = opts[:auth_middlewares]
        assert length(auth_middlewares) == 1

        [{Tesla.Middleware.Headers, headers}] = auth_middlewares
        assert {"authorization", "Bearer sk-test-key"} in headers

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      end)

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())
    end
  end

  describe "call/2 error cases" do
    test "returns MissingModel error when model is nil" do
      assert {:error, %Error.Invalid.MissingModel{}} =
               Pipeline.call(default_messages(), [])
    end

    test "returns InvalidParams error for invalid parameters" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 5.0]

      assert {:error, %Error.Invalid.InvalidParams{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "propagates transport errors" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:error, Error.Provider.RateLimited.exception(retry_after: 30)}
      end)

      assert {:error, %Error.Provider.RateLimited{retry_after: 30}} =
               Pipeline.call(default_messages(), default_opts())
    end

    test "returns MissingCredentials when no credentials found" do
      model = build_model(%{provider: :unknown_provider})
      provider = build_provider(%{id: :unknown_provider, env: []})

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :unknown_provider -> {:ok, provider} end)

      assert {:error, %Error.Invalid.MissingCredentials{}} =
               Pipeline.call(default_messages(), default_opts())
    end
  end

  describe "call/2 telemetry" do
    setup do
      test_pid = self()
      handler_id = "pipeline-telemetry-test-#{inspect(test_pid)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits start and stop events on success" do
      stub_happy_path()

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, start_meta}
      assert start_meta.model == "openai:gpt-4o"
      assert start_meta.provider == :openai

      assert_received {:telemetry_event, [:sycophant, :request, :stop], _, _}
    end

    test "emits start and error events on transport failure" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 500, body: "boom")}
      end)

      assert {:error, _} = Pipeline.call(default_messages(), default_opts())

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :request, :error], _, error_meta}
      assert error_meta.error_class == :provider
    end

    test "does not emit telemetry when model resolution fails" do
      assert {:error, %Error.Invalid.MissingModel{}} =
               Pipeline.call(default_messages(), [])

      refute_received {:telemetry_event, [:sycophant, :request, :start], _, _}
    end
  end

  describe "call/2 with per-request credentials" do
    test "uses per-request credentials over env vars" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        [{Tesla.Middleware.Headers, headers}] = opts[:auth_middlewares]
        assert {"authorization", "Bearer sk-custom"} in headers

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      end)

      opts = default_opts() ++ [credentials: %{api_key: "sk-custom"}]
      assert {:ok, _} = Pipeline.call(default_messages(), opts)
    end
  end

  describe "call/2 context population" do
    test "response context contains input messages plus assistant message" do
      stub_happy_path()

      messages = [Message.system("Be brief"), Message.user("Hi")]
      assert {:ok, %Response{context: context}} = Pipeline.call(messages, default_opts())

      assert length(context.messages) == 3
      assert Enum.at(context.messages, 0).role == :system
      assert Enum.at(context.messages, 1).role == :user
      assert Enum.at(context.messages, 2).role == :assistant
      assert Enum.at(context.messages, 2).content == "Hello!"
    end

    test "response context carries model spec from opts" do
      stub_happy_path()

      assert {:ok, %Response{context: context}} =
               Pipeline.call(default_messages(), default_opts())

      assert context.model == "openai:gpt-4o"
    end

    test "response context carries validated params" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 0.5]
      assert {:ok, %Response{context: context}} = Pipeline.call(default_messages(), opts)

      assert context.params.temperature == 0.5
    end

    test "response context carries tools and provider_params" do
      stub_happy_path()

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{})
      }

      opts = default_opts() ++ [tools: [tool], provider_params: %{"foo" => "bar"}]
      assert {:ok, %Response{context: context}} = Pipeline.call(default_messages(), opts)

      assert context.tools == [tool]
      assert context.provider_params == %{"foo" => "bar"}
    end

    test "assistant message includes tool_calls when present" do
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
               "type" => "function_call",
               "id" => "fc_1",
               "name" => "weather",
               "arguments" => ~s({"city":"Paris"}),
               "call_id" => "call_1"
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      assert {:ok, %Response{context: context}} =
               Pipeline.call(default_messages(), default_opts())

      assistant_msg = List.last(context.messages)
      assert assistant_msg.role == :assistant
      assert assistant_msg.content == nil
      assert length(assistant_msg.tool_calls) == 1
    end
  end

  describe "call/2 tool auto-execution" do
    test "auto-executes tools with :function and loops until text response" do
      model = build_model()
      provider = build_provider()
      counter = :counters.new(1, [:atomics])

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        case count do
          1 ->
            {:ok,
             %{
               "id" => "resp-1",
               "output" => [
                 %{
                   "type" => "function_call",
                   "id" => "fc_1",
                   "name" => "weather",
                   "arguments" => ~s({"city":"Paris"}),
                   "call_id" => "call_1"
                 }
               ],
               "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
             }}

          2 ->
            {:ok,
             %{
               "id" => "resp-2",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "It's sunny in Paris!"}]
                 }
               ],
               "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
             }}
        end
      end)

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{}),
        function: fn %{"city" => city} -> "Sunny in #{city}" end
      }

      opts = default_opts() ++ [tools: [tool]]

      assert {:ok, %Response{text: "It's sunny in Paris!"}} =
               Pipeline.call(default_messages(), opts)

      assert :counters.get(counter, 1) == 2
    end

    test "returns tool_calls when tools have no :function" do
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
               "type" => "function_call",
               "id" => "fc_1",
               "name" => "weather",
               "arguments" => ~s({"city":"Paris"}),
               "call_id" => "call_1"
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{})
      }

      opts = default_opts() ++ [tools: [tool]]
      assert {:ok, %Response{tool_calls: tool_calls}} = Pipeline.call(default_messages(), opts)
      assert length(tool_calls) == 1
      assert hd(tool_calls).name == "weather"
    end
  end

  describe "call/2 response validation" do
    test "validates response against schema and populates object" do
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
      opts = default_opts() ++ [response_schema: schema]

      assert {:ok, %Response{object: %{name: "Alice", age: 30}}} =
               Pipeline.call(default_messages(), opts)
    end

    test "returns error when response fails schema validation" do
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
      opts = default_opts() ++ [response_schema: schema]

      assert {:error, %Error.Invalid.InvalidResponse{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "carries response_schema through context" do
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
                 %{"type" => "output_text", "text" => ~s({"name": "Alice"})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
      opts = default_opts() ++ [response_schema: schema]

      assert {:ok, %Response{context: context}} = Pipeline.call(default_messages(), opts)
      assert context.response_schema == schema
    end
  end
end
