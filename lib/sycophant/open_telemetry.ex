defmodule Sycophant.OpenTelemetry do
  @moduledoc """
  OpenTelemetry bridge for Sycophant telemetry events.

  Attaches `:telemetry` handlers that translate Sycophant request and embedding
  events into OpenTelemetry spans following the GenAI semantic conventions.

  ## Setup

      Sycophant.OpenTelemetry.setup()

  ## Custom Attributes

  Pass an `attribute_mapper` function to enrich spans with application-specific
  attributes. The function receives the telemetry metadata and must return a
  keyword list of `{key, value}` tuples:

      Sycophant.OpenTelemetry.setup(
        attribute_mapper: fn metadata ->
          [{"app.tenant_id", metadata[:tenant_id]}]
        end
      )

  Requires the `opentelemetry_telemetry` optional dependency.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry

  @tracer_id :sycophant

  @request_start [:sycophant, :request, :start]
  @request_stop [:sycophant, :request, :stop]
  @request_error [:sycophant, :request, :error]

  @request_events [@request_start, @request_stop, @request_error]

  @embedding_start [:sycophant, :embedding, :start]
  @embedding_stop [:sycophant, :embedding, :stop]
  @embedding_error [:sycophant, :embedding, :error]

  @embedding_events [@embedding_start, @embedding_stop, @embedding_error]

  @request_handler_id "sycophant-otel-request"
  @embedding_handler_id "sycophant-otel-embedding"

  @doc """
  Attaches OpenTelemetry handlers to Sycophant telemetry events.

  Returns `:ok` on success, or `{:error, :opentelemetry_not_available}` if
  the `opentelemetry_telemetry` dependency is not loaded.

  ## Options

    * `:attribute_mapper` - a function `(map() -> [{String.t(), term()}])`
      whose return values are merged into span attributes.
  """
  @spec setup(keyword()) :: :ok | {:error, :opentelemetry_not_available}
  def setup(opts \\ []) do
    if Code.ensure_loaded?(OpentelemetryTelemetry) do
      config = %{
        attribute_mapper: Keyword.get(opts, :attribute_mapper)
      }

      :telemetry.attach_many(
        @request_handler_id,
        @request_events,
        &handle_request_event/4,
        config
      )

      :telemetry.attach_many(
        @embedding_handler_id,
        @embedding_events,
        &handle_embedding_event/4,
        config
      )

      :ok
    else
      Logger.warning("opentelemetry_telemetry not available, Sycophant OTel bridge disabled")
      {:error, :opentelemetry_not_available}
    end
  end

  @doc "Detaches all OpenTelemetry handlers."
  @spec teardown() :: :ok
  def teardown do
    :telemetry.detach(@request_handler_id)
    :telemetry.detach(@embedding_handler_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def handle_request_event(@request_start, measurements, metadata, config),
    do: handle_start("sycophant.request", "chat", measurements, metadata, config)

  def handle_request_event(@request_stop, _measurements, metadata, config),
    do: handle_stop(metadata, config)

  def handle_request_event(@request_error, _measurements, metadata, config),
    do: handle_error(metadata, config)

  @doc false
  def handle_embedding_event(@embedding_start, measurements, metadata, config),
    do: handle_start("sycophant.embedding", "embeddings", measurements, metadata, config)

  def handle_embedding_event(@embedding_stop, _measurements, metadata, config),
    do: handle_stop(metadata, config)

  def handle_embedding_event(@embedding_error, _measurements, metadata, config),
    do: handle_error(metadata, config)

  defp handle_start(span_name, operation_name, measurements, metadata, config) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      metadata,
      %{start_time: measurements[:system_time]}
    )

    attrs = build_start_attributes(metadata, operation_name)
    attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
    Tracer.set_attributes(attrs)
    :ok
  end

  defp handle_stop(metadata, config) do
    OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    attrs = build_stop_attributes(metadata)
    attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
    Tracer.set_attributes(attrs)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    :ok
  end

  defp handle_error(metadata, config) do
    OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    attrs = build_error_attributes(metadata)
    attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
    Tracer.set_attributes(attrs)
    Tracer.set_status(OpenTelemetry.status(:error, ""))

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    :ok
  end

  @doc false
  @spec build_start_attributes(map(), String.t()) :: [{String.t(), term()}]
  def build_start_attributes(metadata, operation_name) do
    reject_nil_values([
      {"gen_ai.operation.name", operation_name},
      {"gen_ai.provider.name", maybe_to_string(metadata[:provider])},
      {"gen_ai.request.model", metadata[:model]},
      {"sycophant.wire_protocol", wire_protocol_name(metadata[:wire_protocol])},
      {"gen_ai.request.temperature", metadata[:temperature]},
      {"gen_ai.request.top_p", metadata[:top_p]},
      {"gen_ai.request.top_k", metadata[:top_k]},
      {"gen_ai.request.max_tokens", metadata[:max_tokens]}
    ])
  end

  @doc false
  @spec build_stop_attributes(map()) :: [{String.t(), term()}]
  def build_stop_attributes(metadata) do
    usage = metadata[:usage] || %{}

    reject_nil_values([
      {"gen_ai.usage.input_tokens", usage[:input_tokens]},
      {"gen_ai.usage.output_tokens", usage[:output_tokens]},
      {"gen_ai.usage.cache_creation.input_tokens", usage[:cache_creation_input_tokens]},
      {"gen_ai.usage.cache_read.input_tokens", usage[:cache_read_input_tokens]},
      {"gen_ai.response.model", metadata[:response_model]},
      {"gen_ai.response.id", metadata[:response_id]},
      {"gen_ai.response.finish_reasons", finish_reasons(metadata[:finish_reason])}
    ])
  end

  @doc false
  @spec build_error_attributes(map()) :: [{String.t(), term()}]
  def build_error_attributes(metadata) do
    error_type =
      case metadata[:error_class] do
        nil -> "unknown"
        class -> to_string(class)
      end

    [{"error.type", error_type}]
  end

  defp finish_reasons(nil), do: nil
  defp finish_reasons(reason) when is_atom(reason), do: [to_string(reason)]
  defp finish_reasons(reason) when is_binary(reason), do: [reason]
  defp finish_reasons(reasons) when is_list(reasons), do: Enum.map(reasons, &to_string/1)

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(val), do: to_string(val)

  defp wire_protocol_name(nil), do: nil
  defp wire_protocol_name(mod) when is_atom(mod), do: inspect(mod)
  defp wire_protocol_name(other), do: to_string(other)

  defp reject_nil_values(attrs) do
    Enum.reject(attrs, fn {_k, v} -> is_nil(v) end)
  end

  defp maybe_merge_custom(attrs, nil, _metadata), do: attrs

  defp maybe_merge_custom(attrs, mapper, metadata) when is_function(mapper, 1) do
    custom = mapper.(metadata)
    attrs ++ reject_nil_values(custom)
  rescue
    e ->
      Logger.warning("Sycophant.OpenTelemetry attribute_mapper raised: #{inspect(e)}")
      attrs
  end
end
