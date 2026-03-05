defmodule Sycophant.Telemetry do
  @moduledoc """
  Telemetry event definitions and span helper for Sycophant requests.

  Emits the following events:

  * `[:sycophant, :request, :start]` -- when a request begins.
    Measurements: `%{system_time: integer}`.
    Metadata: caller-supplied map (typically model, provider).

  * `[:sycophant, :request, :stop]` -- when a request succeeds.
    Measurements: `%{duration: integer}` (native time units).
    Metadata: caller-supplied map merged with `%{duration, usage}`.

  * `[:sycophant, :request, :error]` -- when a request returns `{:error, _}`.
    Measurements: `%{duration: integer}` (native time units).
    Metadata: caller-supplied map merged with `%{error, error_class}`.

  Uses manual event emission rather than `:telemetry.span/3` because the
  pipeline returns `{:error, _}` tuples instead of raising, and we want
  error metadata on the error event.
  """

  @request_start [:sycophant, :request, :start]
  @request_stop [:sycophant, :request, :stop]
  @request_error [:sycophant, :request, :error]
  @stream_chunk [:sycophant, :stream, :chunk]

  @spec events() :: [[atom(), ...]]
  def events, do: [@request_start, @request_stop, @request_error, @stream_chunk]

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
            usage: format_usage(response.usage)
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

  @spec stream_chunk(Sycophant.StreamChunk.t()) :: :ok
  def stream_chunk(%Sycophant.StreamChunk{} = chunk) do
    :telemetry.execute(@stream_chunk, %{}, %{chunk_type: chunk.type})
  end

  defp format_usage(nil), do: nil

  defp format_usage(%Sycophant.Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: (usage.input_tokens || 0) + (usage.output_tokens || 0)
    }
  end

  defp error_class(%{class: class}), do: class
  defp error_class(_), do: :unknown
end
