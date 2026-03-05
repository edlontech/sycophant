defmodule Sycophant.TelemetryTest do
  use ExUnit.Case, async: false

  alias Sycophant.Telemetry

  setup do
    test_pid = self()
    handler_id = "telemetry-test-#{inspect(test_pid)}"

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

  describe "events/0" do
    test "returns all event names" do
      events = Telemetry.events()

      assert [:sycophant, :request, :start] in events
      assert [:sycophant, :request, :stop] in events
      assert [:sycophant, :request, :error] in events
      assert [:sycophant, :stream, :chunk] in events
      assert length(events) == 4
    end
  end

  describe "span/2" do
    test "emits start and stop events on success with usage metadata" do
      response = %Sycophant.Response{
        text: "Hello",
        usage: %Sycophant.Usage{input_tokens: 10, output_tokens: 5},
        context: %Sycophant.Context{messages: []}
      }

      metadata = %{model: "gpt-4", provider: :openai}

      result = Telemetry.span(metadata, fn -> {:ok, response} end)

      assert result == {:ok, response}

      assert_received {:telemetry_event, [:sycophant, :request, :start], start_measurements,
                       start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.model == "gpt-4"
      assert start_metadata.provider == :openai

      assert_received {:telemetry_event, [:sycophant, :request, :stop], stop_measurements,
                       stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.model == "gpt-4"
      assert stop_metadata.usage == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    end

    test "emits start and error events on failure with error metadata" do
      error = Sycophant.Error.Provider.RateLimited.exception(retry_after: 30)
      metadata = %{model: "gpt-4", provider: :openai}

      result = Telemetry.span(metadata, fn -> {:error, error} end)

      assert result == {:error, error}

      assert_received {:telemetry_event, [:sycophant, :request, :start], _measurements, _metadata}

      assert_received {:telemetry_event, [:sycophant, :request, :error], error_measurements,
                       error_metadata}

      assert is_integer(error_measurements.duration)
      assert error_metadata.model == "gpt-4"
      assert error_metadata.error == error
      assert error_metadata.error_class == :provider
    end

    test "does NOT emit stop on error" do
      error = Sycophant.Error.Provider.RateLimited.exception(retry_after: 30)

      Telemetry.span(%{}, fn -> {:error, error} end)

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :request, :error], _, _}
      refute_received {:telemetry_event, [:sycophant, :request, :stop], _, _}
    end

    test "does NOT emit error on success" do
      response = %Sycophant.Response{
        text: "Hi",
        usage: %Sycophant.Usage{input_tokens: 1, output_tokens: 1},
        context: %Sycophant.Context{messages: []}
      }

      Telemetry.span(%{}, fn -> {:ok, response} end)

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :request, :stop], _, _}
      refute_received {:telemetry_event, [:sycophant, :request, :error], _, _}
    end

    test "handles nil usage in response" do
      response = %Sycophant.Response{
        text: "Hi",
        usage: nil,
        context: %Sycophant.Context{messages: []}
      }

      Telemetry.span(%{}, fn -> {:ok, response} end)

      assert_received {:telemetry_event, [:sycophant, :request, :stop], _measurements,
                       stop_metadata}

      assert stop_metadata.usage == nil
    end

    test "error_class falls back to :unknown for errors without class field" do
      Telemetry.span(%{}, fn -> {:error, %{message: "something broke"}} end)

      assert_received {:telemetry_event, [:sycophant, :request, :error], _measurements,
                       error_metadata}

      assert error_metadata.error_class == :unknown
    end
  end
end
