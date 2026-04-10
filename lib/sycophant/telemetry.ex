defmodule Sycophant.Telemetry do
  @moduledoc """
  Telemetry events for observability and metrics.

  Sycophant emits `:telemetry` events at key points in the request lifecycle,
  following the standard span pattern.

  ## Request Events

    * `[:sycophant, :request, :start]` - Request begins.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{model, provider, wire_protocol, has_tools?, has_stream?}`.

    * `[:sycophant, :request, :stop]` - Request succeeds.
      Measurements: `%{duration: integer}` (native time units).
      Metadata: start metadata merged with `%{duration, usage, response_model, response_id, finish_reason}`.
      Usage includes token counts, cache token counts, and cost fields (from LLMDB pricing).

    * `[:sycophant, :request, :error]` - Request fails.
      Measurements: `%{duration: integer}` (native time units).
      Metadata: start metadata merged with `%{error, error_class}`.

  ## Streaming Events

    * `[:sycophant, :stream, :chunk]` - Individual stream chunk received.
      Measurements: `%{}`.
      Metadata: `%{chunk_type: atom}`.

  ## Embedding Events

    * `[:sycophant, :embedding, :start]` - Embedding request begins.
    * `[:sycophant, :embedding, :stop]` - Embedding request succeeds.
    * `[:sycophant, :embedding, :error]` - Embedding request fails.

  ## Attaching Handlers

      :telemetry.attach_many("sycophant-logger", Sycophant.Telemetry.events(), &handle_event/4, nil)
  """

  @request_start [:sycophant, :request, :start]
  @request_stop [:sycophant, :request, :stop]
  @request_error [:sycophant, :request, :error]
  @stream_chunk [:sycophant, :stream, :chunk]

  @doc "Returns the list of telemetry event names emitted by Sycophant."
  @spec events() :: [[atom(), ...]]
  def events, do: [@request_start, @request_stop, @request_error, @stream_chunk]

  @doc "Wraps a function in start/stop/error telemetry events."
  @spec span(map(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def span(metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute(@request_start, %{system_time: System.system_time()}, metadata)

    case fun.() do
      {:ok, response} = result ->
        duration = System.monotonic_time() - start_time

        stop_metadata =
          Map.merge(metadata, %{
            duration: duration,
            usage: format_usage(response.usage),
            response_model: response.model,
            response_id: get_in(response.metadata || %{}, [:response_id]),
            finish_reason: response.finish_reason
          })

        :telemetry.execute(@request_stop, %{duration: duration}, stop_metadata)
        result

      {:error, error} = result ->
        duration = System.monotonic_time() - start_time

        error_metadata =
          Map.merge(metadata, %{
            error: error,
            error_class: error_class(error)
          })

        :telemetry.execute(@request_error, %{duration: duration}, error_metadata)
        result
    end
  end

  @doc "Emits a telemetry event for a single stream chunk."
  @spec stream_chunk(Sycophant.StreamChunk.t()) :: :ok
  def stream_chunk(%Sycophant.StreamChunk{} = chunk) do
    :telemetry.execute(@stream_chunk, %{}, %{chunk_type: chunk.type})
  end

  defp format_usage(nil), do: nil

  defp format_usage(%Sycophant.Usage{} = usage) do
    usage
    |> Map.from_struct()
    |> Map.put(:total_tokens, (usage.input_tokens || 0) + (usage.output_tokens || 0))
    |> Map.update(:pricing, nil, &format_pricing/1)
  end

  defp format_pricing(nil), do: nil

  defp format_pricing(%Sycophant.Pricing{} = pricing) do
    %{
      currency: pricing.currency,
      components:
        Enum.map(pricing.components, fn comp ->
          comp |> Map.from_struct() |> Map.reject(fn {_k, v} -> is_nil(v) end)
        end)
    }
  end

  defp error_class(%{class: class}), do: class
  defp error_class(_), do: :unknown
end
