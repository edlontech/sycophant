defmodule Sycophant.Agent.TelemetryTest do
  use ExUnit.Case, async: true

  alias Sycophant.Agent.Telemetry

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end

    handler_id = "test-#{inspect(self())}"
    :telemetry.attach_many(handler_id, Telemetry.events(), handler, nil)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "events/0 returns all event names" do
    events = Telemetry.events()
    assert length(events) == 8
    assert [:sycophant, :agent, :start] in events
    assert [:sycophant, :agent, :stop] in events
    assert [:sycophant, :agent, :turn, :start] in events
    assert [:sycophant, :agent, :turn, :stop] in events
    assert [:sycophant, :agent, :tool, :start] in events
    assert [:sycophant, :agent, :tool, :stop] in events
    assert [:sycophant, :agent, :error] in events
    assert [:sycophant, :agent, :state_change] in events
  end

  test "agent_start emits event with metadata" do
    Telemetry.agent_start(%{model: "openai:gpt-4o"})
    assert_receive {:telemetry, [:sycophant, :agent, :start], %{}, %{model: "openai:gpt-4o"}}
  end

  test "agent_stop emits event with measurements and metadata" do
    Telemetry.agent_stop(%{duration: 5000}, %{reason: :normal})

    assert_receive {:telemetry, [:sycophant, :agent, :stop], %{duration: 5000},
                    %{reason: :normal}}
  end

  test "turn_start emits event with metadata" do
    Telemetry.turn_start(%{turn_number: 1})
    assert_receive {:telemetry, [:sycophant, :agent, :turn, :start], %{}, %{turn_number: 1}}
  end

  test "turn_stop emits event with measurements and metadata" do
    Telemetry.turn_stop(%{duration: 1000, input_tokens: 50}, %{turn_number: 1})

    assert_receive {:telemetry, [:sycophant, :agent, :turn, :stop],
                    %{duration: 1000, input_tokens: 50}, %{turn_number: 1}}
  end

  test "tool_start emits event with metadata" do
    Telemetry.tool_start(%{tool_name: "search"})
    assert_receive {:telemetry, [:sycophant, :agent, :tool, :start], %{}, %{tool_name: "search"}}
  end

  test "tool_stop emits event with measurements and metadata" do
    Telemetry.tool_stop(%{duration: 200}, %{tool_name: "search"})

    assert_receive {:telemetry, [:sycophant, :agent, :tool, :stop], %{duration: 200},
                    %{tool_name: "search"}}
  end

  test "error emits event with metadata" do
    Telemetry.error(%{error: :timeout, message: "request timed out"})

    assert_receive {:telemetry, [:sycophant, :agent, :error], %{},
                    %{error: :timeout, message: "request timed out"}}
  end

  test "state_change emits from/to states" do
    Telemetry.state_change(:idle, :generating)

    assert_receive {:telemetry, [:sycophant, :agent, :state_change], %{},
                    %{from_state: :idle, to_state: :generating}}
  end
end
