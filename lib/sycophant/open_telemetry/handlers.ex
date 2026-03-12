if Code.ensure_loaded?(OpenTelemetry.Tracer) do
  defmodule Sycophant.OpenTelemetry.Handlers do
    @moduledoc false

    require OpenTelemetry.Tracer, as: Tracer
    require OpenTelemetry

    @tracer_id :sycophant

    @doc false
    @spec handle_start(String.t(), String.t(), map(), map(), keyword()) :: :ok
    def handle_start(span_name, operation_name, measurements, metadata, config) do
      OpentelemetryTelemetry.start_telemetry_span(
        @tracer_id,
        span_name,
        metadata,
        %{start_time: measurements[:system_time]}
      )

      attrs = Sycophant.OpenTelemetry.build_start_attributes(metadata, operation_name)
      attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
      Tracer.set_attributes(attrs)
      :ok
    end

    @doc false
    @spec handle_stop(map(), keyword()) :: :ok
    def handle_stop(metadata, config) do
      OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

      attrs = Sycophant.OpenTelemetry.build_stop_attributes(metadata)
      attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
      Tracer.set_attributes(attrs)

      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
      :ok
    end

    @doc false
    @spec handle_error(map(), keyword()) :: :ok
    def handle_error(metadata, config) do
      OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

      attrs = Sycophant.OpenTelemetry.build_error_attributes(metadata)
      attrs = maybe_merge_custom(attrs, config[:attribute_mapper], metadata)
      Tracer.set_attributes(attrs)
      Tracer.set_status(OpenTelemetry.status(:error, ""))

      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
      :ok
    end

    defp maybe_merge_custom(attrs, nil, _metadata), do: attrs

    defp maybe_merge_custom(attrs, mapper, metadata) when is_function(mapper, 1) do
      custom = mapper.(metadata)
      attrs ++ Sycophant.OpenTelemetry.reject_nil_values(custom)
    rescue
      e ->
        require Logger
        Logger.warning("Sycophant.OpenTelemetry attribute_mapper raised: #{inspect(e)}")
        attrs
    end
  end
end
