defmodule Sycophant.OpenTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Sycophant.OpenTelemetry

  setup do
    on_exit(fn -> OpenTelemetry.teardown() end)
    :ok
  end

  describe "setup/1" do
    test "attaches request and embedding handlers" do
      assert :ok = OpenTelemetry.setup()

      request_handlers = :telemetry.list_handlers([:sycophant, :request, :start])
      assert Enum.any?(request_handlers, &(&1.id == "sycophant-otel-request"))

      embedding_handlers = :telemetry.list_handlers([:sycophant, :embedding, :start])
      assert Enum.any?(embedding_handlers, &(&1.id == "sycophant-otel-embedding"))
    end

    test "attaches handlers for all request event phases" do
      OpenTelemetry.setup()

      for phase <- [:start, :stop, :error] do
        handlers = :telemetry.list_handlers([:sycophant, :request, phase])

        assert Enum.any?(handlers, &(&1.id == "sycophant-otel-request")),
               "expected handler for [:sycophant, :request, #{phase}]"
      end
    end

    test "attaches handlers for all embedding event phases" do
      OpenTelemetry.setup()

      for phase <- [:start, :stop, :error] do
        handlers = :telemetry.list_handlers([:sycophant, :embedding, phase])

        assert Enum.any?(handlers, &(&1.id == "sycophant-otel-embedding")),
               "expected handler for [:sycophant, :embedding, #{phase}]"
      end
    end
  end

  describe "teardown/0" do
    test "detaches all handlers" do
      OpenTelemetry.setup()
      OpenTelemetry.teardown()

      request_handlers = :telemetry.list_handlers([:sycophant, :request, :start])
      refute Enum.any?(request_handlers, &(&1.id == "sycophant-otel-request"))

      embedding_handlers = :telemetry.list_handlers([:sycophant, :embedding, :start])
      refute Enum.any?(embedding_handlers, &(&1.id == "sycophant-otel-embedding"))
    end

    test "is idempotent" do
      assert :ok = OpenTelemetry.teardown()
      assert :ok = OpenTelemetry.teardown()
    end
  end

  describe "build_start_attributes/2" do
    test "returns gen_ai attributes for chat operation" do
      metadata = %{
        model: "anthropic:claude-haiku-4-5-20251001",
        provider: :anthropic,
        wire_protocol: Sycophant.WireProtocol.AnthropicMessages,
        temperature: 0.7,
        top_p: 0.9,
        top_k: 40,
        max_tokens: 1024
      }

      attrs = OpenTelemetry.build_start_attributes(metadata, "chat")

      assert {"gen_ai.operation.name", "chat"} in attrs
      assert {"gen_ai.provider.name", "anthropic"} in attrs
      assert {"gen_ai.request.model", "anthropic:claude-haiku-4-5-20251001"} in attrs
      assert {"sycophant.wire_protocol", "Sycophant.WireProtocol.AnthropicMessages"} in attrs
      assert {"gen_ai.request.temperature", 0.7} in attrs
      assert {"gen_ai.request.top_p", 0.9} in attrs
      assert {"gen_ai.request.top_k", 40} in attrs
      assert {"gen_ai.request.max_tokens", 1024} in attrs
    end

    test "returns gen_ai attributes for embeddings operation" do
      metadata = %{provider: :openai, model: "openai:text-embedding-3-small"}

      attrs = OpenTelemetry.build_start_attributes(metadata, "embeddings")

      assert {"gen_ai.operation.name", "embeddings"} in attrs
      assert {"gen_ai.provider.name", "openai"} in attrs
    end

    test "omits nil optional values" do
      metadata = %{
        model: "openai:gpt-4",
        provider: :openai,
        wire_protocol: nil,
        temperature: nil,
        top_p: nil,
        top_k: nil,
        max_tokens: nil
      }

      attrs = OpenTelemetry.build_start_attributes(metadata, "chat")

      keys = Enum.map(attrs, &elem(&1, 0))
      refute "sycophant.wire_protocol" in keys
      refute "gen_ai.request.temperature" in keys
      refute "gen_ai.request.top_p" in keys
      refute "gen_ai.request.top_k" in keys
      refute "gen_ai.request.max_tokens" in keys
    end

    test "handles missing keys in metadata" do
      attrs = OpenTelemetry.build_start_attributes(%{}, "chat")

      assert {"gen_ai.operation.name", "chat"} in attrs
      keys = Enum.map(attrs, &elem(&1, 0))
      refute "gen_ai.provider.name" in keys
      refute "gen_ai.request.temperature" in keys
      refute "gen_ai.request.model" in keys
    end
  end

  describe "build_stop_attributes/1" do
    test "returns usage and response attributes" do
      metadata = %{
        usage: %{
          input_tokens: 100,
          output_tokens: 50,
          cache_creation_input_tokens: 10,
          cache_read_input_tokens: 20
        },
        response_model: "gpt-4-turbo",
        response_id: "chatcmpl-abc123",
        finish_reason: :stop
      }

      attrs = OpenTelemetry.build_stop_attributes(metadata)

      assert {"gen_ai.usage.input_tokens", 100} in attrs
      assert {"gen_ai.usage.output_tokens", 50} in attrs
      assert {"gen_ai.usage.cache_creation.input_tokens", 10} in attrs
      assert {"gen_ai.usage.cache_read.input_tokens", 20} in attrs
      assert {"gen_ai.response.model", "gpt-4-turbo"} in attrs
      assert {"gen_ai.response.id", "chatcmpl-abc123"} in attrs
      assert {"gen_ai.response.finish_reasons", ["stop"]} in attrs
    end

    test "omits nil usage fields" do
      metadata = %{
        usage: %{input_tokens: 10, output_tokens: 5},
        finish_reason: :stop
      }

      attrs = OpenTelemetry.build_stop_attributes(metadata)
      keys = Enum.map(attrs, &elem(&1, 0))

      refute "gen_ai.usage.cache_creation.input_tokens" in keys
      refute "gen_ai.usage.cache_read.input_tokens" in keys
    end

    test "handles nil usage gracefully" do
      metadata = %{usage: nil, finish_reason: nil}

      attrs = OpenTelemetry.build_stop_attributes(metadata)
      keys = Enum.map(attrs, &elem(&1, 0))

      refute "gen_ai.usage.input_tokens" in keys
      refute "gen_ai.usage.output_tokens" in keys
      refute "gen_ai.response.finish_reasons" in keys
    end

    test "converts atom finish_reason to string list" do
      metadata = %{finish_reason: :max_tokens}
      attrs = OpenTelemetry.build_stop_attributes(metadata)
      assert {"gen_ai.response.finish_reasons", ["max_tokens"]} in attrs
    end

    test "wraps string finish_reason in list" do
      metadata = %{finish_reason: "stop"}
      attrs = OpenTelemetry.build_stop_attributes(metadata)
      assert {"gen_ai.response.finish_reasons", ["stop"]} in attrs
    end
  end

  describe "build_error_attributes/1" do
    test "returns error type from error_class" do
      attrs = OpenTelemetry.build_error_attributes(%{error_class: :provider})
      assert [{"error.type", "provider"}] == attrs
    end

    test "returns unknown when error_class is nil" do
      attrs = OpenTelemetry.build_error_attributes(%{error_class: nil})
      assert [{"error.type", "unknown"}] == attrs
    end

    test "returns unknown when error_class is missing" do
      attrs = OpenTelemetry.build_error_attributes(%{})
      assert [{"error.type", "unknown"}] == attrs
    end
  end

  describe "handler callbacks with mocked OpentelemetryTelemetry" do
    test "start handler calls start_telemetry_span and sets attributes" do
      stub(OpentelemetryTelemetry, :start_telemetry_span, fn _tracer, _name, _meta, _opts ->
        :undefined
      end)

      metadata = %{model: "openai:gpt-4", provider: :openai, wire_protocol: nil}
      measurements = %{system_time: System.system_time()}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_request_event(
                 [:sycophant, :request, :start],
                 measurements,
                 metadata,
                 config
               )
    end

    test "stop handler calls set_current, then end_telemetry_span" do
      stub(OpentelemetryTelemetry, :set_current_telemetry_span, fn _tracer, _meta ->
        :undefined
      end)

      stub(OpentelemetryTelemetry, :end_telemetry_span, fn _tracer, _meta -> :ok end)

      metadata = %{usage: %{input_tokens: 10, output_tokens: 5}, finish_reason: :stop}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_request_event(
                 [:sycophant, :request, :stop],
                 %{duration: 1000},
                 metadata,
                 config
               )
    end

    test "error handler calls set_current, sets error status, then end_telemetry_span" do
      stub(OpentelemetryTelemetry, :set_current_telemetry_span, fn _tracer, _meta ->
        :undefined
      end)

      stub(OpentelemetryTelemetry, :end_telemetry_span, fn _tracer, _meta -> :ok end)

      metadata = %{error_class: :provider, error: %{message: "rate limited"}}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_request_event(
                 [:sycophant, :request, :error],
                 %{duration: 500},
                 metadata,
                 config
               )
    end

    test "embedding start handler calls start_telemetry_span" do
      stub(OpentelemetryTelemetry, :start_telemetry_span, fn _tracer, _name, _meta, _opts ->
        :undefined
      end)

      metadata = %{model: "openai:text-embedding-3-small", provider: :openai}
      measurements = %{system_time: System.system_time()}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_embedding_event(
                 [:sycophant, :embedding, :start],
                 measurements,
                 metadata,
                 config
               )
    end

    test "embedding stop handler calls set_current and end_telemetry_span" do
      stub(OpentelemetryTelemetry, :set_current_telemetry_span, fn _tracer, _meta ->
        :undefined
      end)

      stub(OpentelemetryTelemetry, :end_telemetry_span, fn _tracer, _meta -> :ok end)

      metadata = %{usage: %{input_tokens: 50}, finish_reason: nil}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_embedding_event(
                 [:sycophant, :embedding, :stop],
                 %{duration: 200},
                 metadata,
                 config
               )
    end

    test "embedding error handler sets error status" do
      stub(OpentelemetryTelemetry, :set_current_telemetry_span, fn _tracer, _meta ->
        :undefined
      end)

      stub(OpentelemetryTelemetry, :end_telemetry_span, fn _tracer, _meta -> :ok end)

      metadata = %{error_class: :invalid, error: %{message: "bad input"}}
      config = %{attribute_mapper: nil}

      assert :ok =
               OpenTelemetry.handle_embedding_event(
                 [:sycophant, :embedding, :error],
                 %{duration: 100},
                 metadata,
                 config
               )
    end
  end

  describe "custom attribute_mapper" do
    test "merges custom attributes from mapper into start attributes" do
      stub(OpentelemetryTelemetry, :start_telemetry_span, fn _tracer, _name, _meta, _opts ->
        :undefined
      end)

      mapper = fn meta -> [{"app.custom", meta[:provider]}] end
      metadata = %{model: "openai:gpt-4", provider: :openai}
      config = %{attribute_mapper: mapper}

      assert :ok =
               OpenTelemetry.handle_request_event(
                 [:sycophant, :request, :start],
                 %{system_time: System.system_time()},
                 metadata,
                 config
               )
    end

    test "mapper crash does not break the handler" do
      stub(OpentelemetryTelemetry, :start_telemetry_span, fn _tracer, _name, _meta, _opts ->
        :undefined
      end)

      mapper = fn _meta -> raise "boom" end
      metadata = %{model: "openai:gpt-4", provider: :openai}
      config = %{attribute_mapper: mapper}

      assert :ok =
               OpenTelemetry.handle_request_event(
                 [:sycophant, :request, :start],
                 %{system_time: System.system_time()},
                 metadata,
                 config
               )
    end

    test "mapper nil values are filtered out" do
      mapper = fn _meta -> [{"app.present", "yes"}, {"app.absent", nil}] end

      metadata = %{model: "openai:gpt-4", provider: :openai}
      attrs = OpenTelemetry.build_start_attributes(metadata, "chat")
      custom = mapper.(metadata)
      merged = attrs ++ Enum.reject(custom, fn {_k, v} -> is_nil(v) end)

      keys = Enum.map(merged, &elem(&1, 0))
      assert "app.present" in keys
      refute "app.absent" in keys
    end
  end
end
