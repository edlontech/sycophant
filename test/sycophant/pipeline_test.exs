defmodule Sycophant.PipelineTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Sycophant.Error
  alias Sycophant.Message
  alias Sycophant.Pipeline
  alias Sycophant.Response
  alias Sycophant.Telemetry

  setup :set_mimic_global
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

    test "soft-drops params not in wire schema without erroring" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 0.5, bogus_param: "ignored"]

      assert {:ok, %Response{}} = Pipeline.call(default_messages(), opts)
    end

    test "returns error for invalid param values against wire schema" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 5.0]

      assert {:error, %Error.Invalid.InvalidParams{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "applies model constraints to drop unsupported params" do
      model =
        build_model(%{
          extra: %{
            wire: %{protocol: "openai_responses"},
            constraints: %{temperature: "unsupported"}
          }
        })

      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn payload, _opts ->
        refute Map.has_key?(payload, "temperature")

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

      opts = default_opts() ++ [temperature: 0.5]
      assert {:ok, %Response{}} = Pipeline.call(default_messages(), opts)
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

    test "start metadata includes validated params when provided" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 0.7]
      assert {:ok, _} = Pipeline.call(default_messages(), opts)

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, start_meta}
      assert start_meta.temperature == 0.7
    end

    test "start metadata has nil for params not provided" do
      stub_happy_path()

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, start_meta}
      assert is_nil(start_meta.temperature)
      assert is_nil(start_meta.top_p)
    end

    test "does not emit telemetry when param validation fails" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 5.0]
      assert {:error, _} = Pipeline.call(default_messages(), opts)

      refute_received {:telemetry_event, [:sycophant, :request, :start], _, _}
    end

    test "does not emit telemetry when credential resolution fails" do
      model = build_model(%{provider: :unknown_provider})
      provider = build_provider(%{id: :unknown_provider, env: []})

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :unknown_provider -> {:ok, provider} end)

      assert {:error, _} = Pipeline.call(default_messages(), default_opts())

      refute_received {:telemetry_event, [:sycophant, :request, :start], _, _}
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

    test "response context does not carry model" do
      stub_happy_path()

      assert {:ok, %Response{context: context}} =
               Pipeline.call(default_messages(), default_opts())

      refute Map.has_key?(context, :model)
    end

    test "response context carries validated params as plain map" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 0.5]
      assert {:ok, %Response{context: context}} = Pipeline.call(default_messages(), opts)

      assert is_map(context.params)
      assert context.params.temperature == 0.5
    end

    test "response context carries tools" do
      stub_happy_path()

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{})
      }

      opts = default_opts() ++ [tools: [tool]]
      assert {:ok, %Response{context: context}} = Pipeline.call(default_messages(), opts)

      assert [%Sycophant.Tool{name: "weather"}] = context.tools
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

  describe "call/2 citations in context" do
    test "attaches a cited Content.Text to the assistant message" do
      model =
        build_model(%{
          id: "claude-haiku-4-5-20251001",
          name: "Claude Haiku",
          provider: :anthropic,
          extra: %{wire: %{protocol: "anthropic_messages"}}
        })

      provider =
        build_provider(%{
          id: :anthropic,
          name: "Anthropic",
          base_url: "https://api.anthropic.com/v1",
          env: ["ANTHROPIC_API_KEY"]
        })

      stub(LLMDB, :model, fn "anthropic:claude-haiku-4-5-20251001" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :anthropic -> {:ok, provider} end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "type" => "message",
           "role" => "assistant",
           "model" => "claude-haiku-4-5-20251001",
           "stop_reason" => "end_turn",
           "content" => [
             %{
               "type" => "text",
               "text" => "The capital is Paris.",
               "citations" => [
                 %{
                   "type" => "page_location",
                   "cited_text" => "Paris is the capital",
                   "document_index" => 0,
                   "start_page_number" => 1,
                   "end_page_number" => 2
                 }
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      opts = [
        model: "anthropic:claude-haiku-4-5-20251001",
        credentials: %{api_key: "sk-ant-test"}
      ]

      assert {:ok, response} = Pipeline.call([Message.user("Capital of France?")], opts)

      assert response.text == "The capital is Paris."
      assert [%Sycophant.Citation{type: :page_location}] = response.citations

      assistant_msg = List.last(response.context.messages)
      assert assistant_msg.role == :assistant

      assert [
               %Sycophant.Message.Content.Text{
                 text: "The capital is Paris.",
                 citations: [
                   %Sycophant.Citation{type: :page_location, start_index: 1, end_index: 2}
                 ]
               }
             ] = assistant_msg.content
    end

    test "non-cited responses keep plain-string assistant content" do
      stub_happy_path()

      assert {:ok, %Response{context: context}} =
               Pipeline.call([Message.user("Hi")], default_opts())

      assert List.last(context.messages).content == "Hello!"
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

    test "auto_execute_tools: false skips tool loop even when tools have :function" do
      model = build_model()
      provider = build_provider()
      counter = :counters.new(1, [:atomics])

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        :counters.add(counter, 1, 1)

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
        parameters: Zoi.map(%{}),
        function: fn _args ->
          flunk("function must not be executed when auto_execute_tools: false")
        end
      }

      opts = default_opts() ++ [tools: [tool], auto_execute_tools: false]

      assert {:ok, %Response{tool_calls: [%{name: "weather"}]}} =
               Pipeline.call(default_messages(), opts)

      assert :counters.get(counter, 1) == 1
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

    test "context does not carry response_schema" do
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
      refute Map.has_key?(context, :response_schema)
    end
  end

  describe "call/2 schema normalization" do
    test "normalizes Zoi response_schema into JSON Schema map for wire encoding" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        text = payload["text"] || %{}
        format = text["format"] || payload["response_format"]

        if format do
          schema = format["schema"] || format
          assert is_map(schema)
          refute is_struct(schema)
        end

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

    test "normalizes JSON Schema map response_schema and validates" do
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

      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name", "age"]
      }

      opts = default_opts() ++ [response_schema: schema]

      assert {:ok, %Response{object: %{"name" => "Alice", "age" => 30}}} =
               Pipeline.call(default_messages(), opts)
    end

    test "normalizes tool parameters from Zoi to JSON Schema map" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        tools = payload["tools"] || []

        if tools != [] do
          [tool | _] = tools
          params = tool["parameters"] || get_in(tool, ["function", "parameters"])
          assert is_map(params)
          refute is_struct(params)
        end

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "sunny"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{city: Zoi.string()})
      }

      opts = default_opts() ++ [tools: [tool]]

      assert {:ok, %Response{}} = Pipeline.call(default_messages(), opts)
    end

    test "skips normalization for already-normalized tools" do
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
               "content" => [%{"type" => "output_text", "text" => "ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      json_params = %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }

      {:ok, normalized} = Sycophant.Schema.Normalizer.normalize(json_params)

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: json_params,
        schema_source: :json_schema,
        resolved_schema: normalized
      }

      opts = default_opts() ++ [tools: [tool]]

      assert {:ok, %Response{}} = Pipeline.call(default_messages(), opts)
    end

    test "returns error for invalid response_schema" do
      stub_happy_path()

      opts =
        default_opts() ++
          [response_schema: %{"type" => "bogus_type_that_is_invalid", "properties" => 123}]

      assert {:error, _} = Pipeline.call(default_messages(), opts)
    end
  end

  describe "call/2 with credentials base_url override" do
    test "uses base_url from credentials instead of LLMDB base_url" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        assert opts[:base_url] == "https://custom.azure.endpoint/openai"

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

      opts =
        default_opts() ++
          [credentials: %{api_key: "sk-custom", base_url: "https://custom.azure.endpoint/openai"}]

      assert {:ok, _} = Pipeline.call(default_messages(), opts)
    end

    test "falls back to LLMDB base_url when credentials lack base_url" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        assert opts[:base_url] == "https://api.openai.com/v1"

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

  describe "call/2 streaming" do
    defp completed_response_body do
      %{
        "id" => "resp-123",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello World"}]
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }
    end

    defp stream_events do
      [
        %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "Hello "})},
        %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "World"})},
        %{
          event: "response.completed",
          data: JSON.encode!(%{"response" => completed_response_body()})
        }
      ]
    end

    defp stub_stream_happy_path do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        {:ok, on_event.(stream_events())}
      end)
    end

    test "text deltas fire callback and returns final Response" do
      stub_stream_happy_path()
      test_pid = self()

      callback = fn chunk -> send(test_pid, {:chunk, chunk}) end
      opts = default_opts() ++ [stream: callback]

      assert {:ok, %Response{text: "Hello World"}} =
               Pipeline.call(default_messages(), opts)

      assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta, data: "Hello "}}
      assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta, data: "World"}}
    end

    test "streaming composes with tool auto-execution" do
      model = build_model()
      provider = build_provider()
      counter = :counters.new(1, [:atomics])

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        events =
          case count do
            1 ->
              tool_call_body = %{
                "id" => "resp-1",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "function_call",
                    "call_id" => "call_1",
                    "name" => "weather",
                    "arguments" => ~s({"city":"Paris"})
                  }
                ],
                "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
              }

              [
                %{
                  event: "response.function_call_arguments.delta",
                  data:
                    JSON.encode!(%{"item_id" => "call_1", "delta" => "{}", "output_index" => 0})
                },
                %{
                  event: "response.completed",
                  data: JSON.encode!(%{"response" => tool_call_body})
                }
              ]

            2 ->
              final_body = %{
                "id" => "resp-2",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "content" => [%{"type" => "output_text", "text" => "Sunny in Paris!"}]
                  }
                ],
                "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
              }

              [
                %{
                  event: "response.output_text.delta",
                  data: JSON.encode!(%{"delta" => "Sunny in Paris!"})
                },
                %{event: "response.completed", data: JSON.encode!(%{"response" => final_body})}
              ]
          end

        {:ok, on_event.(events)}
      end)

      tool = %Sycophant.Tool{
        name: "weather",
        description: "Get weather",
        parameters: Zoi.map(%{}),
        function: fn %{"city" => city} -> "Sunny in #{city}" end
      }

      callback = fn _chunk -> :ok end
      opts = default_opts() ++ [tools: [tool], stream: callback]

      assert {:ok, %Response{text: "Sunny in Paris!"}} =
               Pipeline.call(default_messages(), opts)

      assert :counters.get(counter, 1) == 2
    end

    test "stream context preserves stream callback for continuation" do
      stub_stream_happy_path()

      callback = fn _chunk -> :ok end
      opts = default_opts() ++ [stream: callback]

      assert {:ok, %Response{context: context}} =
               Pipeline.call(default_messages(), opts)

      assert context.stream == callback
    end

    test "non-streaming calls still work when stream is nil" do
      stub_happy_path()

      assert {:ok, %Response{text: "Hello!"}} =
               Pipeline.call(default_messages(), default_opts())
    end

    test "returns InvalidParams when stream is not a function/1 or tuple" do
      stub_happy_path()

      opts = default_opts() ++ [stream: true]

      assert {:error, %Error.Invalid.InvalidParams{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "accumulator threads through stream chunks with tuple form" do
      stub_stream_happy_path()

      stream =
        {[],
         fn
           %Sycophant.StreamChunk{type: :text_delta, data: text}, acc -> [text | acc]
           %Sycophant.StreamChunk{type: :done}, _acc -> :ok
           _chunk, acc -> acc
         end}

      opts = default_opts() ++ [stream: stream]

      assert {:ok, %Response{text: "Hello World"}} =
               Pipeline.call(default_messages(), opts)
    end

    test "emits :done chunk as last event for tuple form" do
      stub_stream_happy_path()
      test_pid = self()

      stream =
        {nil,
         fn chunk, acc ->
           send(test_pid, {:chunk, chunk.type})
           acc
         end}

      opts = default_opts() ++ [stream: stream]

      assert {:ok, _} = Pipeline.call(default_messages(), opts)

      assert_received {:chunk, :text_delta}
      assert_received {:chunk, :text_delta}
      assert_received {:chunk, :done}
    end

    test "emits :done chunk for legacy 1-arity callback" do
      stub_stream_happy_path()
      test_pid = self()

      callback = fn chunk -> send(test_pid, {:chunk, chunk.type}) end
      opts = default_opts() ++ [stream: callback]

      assert {:ok, _} = Pipeline.call(default_messages(), opts)

      assert_received {:chunk, :text_delta}
      assert_received {:chunk, :text_delta}
      assert_received {:chunk, :done}
    end

    test "emits :done chunk with :max_tokens finish_reason when response.incomplete arrives" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      incomplete_events = [
        %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "partial"})},
        %{
          event: "response.incomplete",
          data:
            JSON.encode!(%{
              "response" => %{
                "status" => "incomplete",
                "incomplete_details" => %{"reason" => "max_output_tokens"},
                "output" => []
              }
            })
        }
      ]

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        {:ok, on_event.(incomplete_events)}
      end)

      test_pid = self()
      callback = fn chunk -> send(test_pid, {:chunk, chunk.type}) end
      opts = default_opts() ++ [stream: callback]

      assert {:ok, response} = Pipeline.call(default_messages(), opts)
      assert response.finish_reason == :max_tokens

      assert_received {:chunk, :text_delta}
      assert_received {:chunk, :done}
      refute_received {:chunk, :incomplete}
    end

    test "emits :failed chunk when response.failed arrives" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      failed_events = [
        %{
          event: "response.failed",
          data:
            JSON.encode!(%{
              "response" => %{
                "status" => "failed",
                "error" => %{"code" => "server_error", "message" => "boom"}
              }
            })
        }
      ]

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        {:ok, on_event.(failed_events)}
      end)

      test_pid = self()

      callback = fn chunk ->
        send(test_pid, {:chunk, chunk.type, chunk.data})
      end

      opts = default_opts() ++ [stream: callback]

      assert {:error, %Sycophant.Error.Provider.ServerError{body: "boom"}} =
               Pipeline.call(default_messages(), opts)

      assert_received {:chunk, :failed, %Sycophant.Error.Provider.ServerError{body: "boom"}}
    end

    test "stream context preserves tuple callback for continuation" do
      stub_stream_happy_path()

      stream = {[], fn _chunk, acc -> acc end}
      opts = default_opts() ++ [stream: stream]

      assert {:ok, %Response{context: context}} =
               Pipeline.call(default_messages(), opts)

      assert context.stream == stream
    end

    test "propagates transport error from Transport.stream" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :stream, fn _payload, _opts, _on_event ->
        {:error, Error.Provider.ServerError.exception(status: 500, body: "stream failed")}
      end)

      callback = fn _chunk -> :ok end
      opts = default_opts() ++ [stream: callback]

      assert {:error, %Error.Provider.ServerError{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "returns ResponseInvalid when stream ends without completed response" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      events = [
        %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "partial"})}
      ]

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        {:ok, on_event.(events)}
      end)

      callback = fn _chunk -> :ok end
      opts = default_opts() ++ [stream: callback]

      assert {:error, %Error.Provider.ResponseInvalid{}} =
               Pipeline.call(default_messages(), opts)
    end
  end

  describe "call/2 usage cost enrichment" do
    test "populates cost fields when model has cost data" do
      model =
        build_model(%{
          pricing: %{
            currency: "USD",
            components: [
              %{id: "token.input", kind: "token", unit: "tokens", per: 1_000_000, rate: 3.0},
              %{id: "token.output", kind: "token", unit: "tokens", per: 1_000_000, rate: 15.0},
              %{id: "token.cache_read", kind: "token", unit: "tokens", per: 1_000_000, rate: 0.3},
              %{
                id: "token.cache_write",
                kind: "token",
                unit: "tokens",
                per: 1_000_000,
                rate: 3.75
              }
            ]
          }
        })

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
           "usage" => %{"input_tokens" => 1000, "output_tokens" => 500}
         }}
      end)

      assert {:ok, %Response{usage: usage}} =
               Pipeline.call(default_messages(), default_opts())

      assert_in_delta usage.input_cost, 0.003, 1.0e-9
      assert_in_delta usage.output_cost, 0.0075, 1.0e-9
      assert_in_delta usage.total_cost, 0.0105, 1.0e-9
    end

    test "leaves cost fields nil when model has no cost data" do
      stub_happy_path()

      assert {:ok, %Response{usage: usage}} =
               Pipeline.call(default_messages(), default_opts())

      assert is_nil(usage.input_cost)
      assert is_nil(usage.output_cost)
      assert is_nil(usage.total_cost)
    end
  end

  describe "call/2 streaming telemetry" do
    setup do
      test_pid = self()
      handler_id = "pipeline-stream-telemetry-test-#{inspect(test_pid)}"

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

    test "emits stream.chunk events during streaming" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      completed = %{
        "id" => "resp-123",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hi"}]
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      events = [
        %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "Hi"})},
        %{event: "response.completed", data: JSON.encode!(%{"response" => completed})}
      ]

      stub(Sycophant.Transport, :stream, fn _payload, _opts, on_event ->
        {:ok, on_event.(events)}
      end)

      callback = fn _chunk -> :ok end
      opts = default_opts() ++ [stream: callback]

      assert {:ok, _} = Pipeline.call(default_messages(), opts)

      assert_received {:telemetry_event, [:sycophant, :stream, :chunk], %{},
                       %{chunk_type: :text_delta}}
    end
  end

  describe "github_copilot - capability gating" do
    setup do
      Mimic.copy(Sycophant.Auth.GithubCopilot.TokenCache)

      stub(Sycophant.Auth.GithubCopilot.TokenCache, :fetch, fn _host, _token ->
        {:ok,
         %Sycophant.Auth.GithubCopilot.TokenCache.Entry{
           copilot_token: "tid=test",
           expires_at: DateTime.add(DateTime.utc_now(), 1500, :second),
           endpoints: %{api: "https://api.individual.githubcopilot.com"},
           fetched_at: DateTime.utc_now()
         }}
      end)

      :ok
    end

    defp copilot_messages, do: [%Message{role: :user, content: "hi"}]

    defp fake_openai_response do
      %{
        "id" => "chatcmpl-test",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "hello"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }
    end

    test "drops temperature for models flagged extra.temperature == false (gpt-5.5)" do
      expect(Sycophant.Transport, :call, fn payload, _opts ->
        refute Map.has_key?(payload, "temperature")
        {:ok, fake_openai_response()}
      end)

      assert {:ok, _} =
               Pipeline.call(copilot_messages(),
                 model: "github_copilot:gpt-5.5",
                 temperature: 0.7,
                 credentials: %{github_token: "ghp_x"}
               )
    end

    test "preserves temperature for models flagged extra.temperature == true (gpt-4.1)" do
      expect(Sycophant.Transport, :call, fn payload, _opts ->
        assert payload["temperature"] == 0.7
        {:ok, fake_openai_response()}
      end)

      assert {:ok, _} =
               Pipeline.call(copilot_messages(),
                 model: "github_copilot:gpt-4.1",
                 temperature: 0.7,
                 credentials: %{github_token: "ghp_x"}
               )
    end

    test "rejects response_schema for Copilot (json.schema == false)" do
      schema = %{type: :object, properties: %{x: %{type: :string}}, required: [:x]}

      assert {:error, %Error.Invalid.InvalidParams{}} =
               Pipeline.call(copilot_messages(),
                 model: "github_copilot:gpt-4.1",
                 response_schema: schema,
                 credentials: %{github_token: "ghp_x"}
               )
    end

    test "calls Auth.prepare_credentials_for and uses base_url from token exchange" do
      expect(Sycophant.Transport, :call, fn _payload, opts ->
        assert opts[:base_url] == "https://api.individual.githubcopilot.com"
        {:ok, fake_openai_response()}
      end)

      assert {:ok, _} =
               Pipeline.call(copilot_messages(),
                 model: "github_copilot:gpt-4.1",
                 credentials: %{github_token: "ghp_x"}
               )
    end
  end
end
