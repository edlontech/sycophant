defmodule Sycophant.Agent.Telemetry do
  @moduledoc """
  Telemetry events for the agent lifecycle.

  Emits `:telemetry` events at key points during agent execution,
  following the standard span pattern.

  ## Agent Events

    * `[:sycophant, :agent, :start]` - Agent starts.
      Measurements: `%{}`.
      Metadata: caller-provided (e.g. `%{model: ...}`).

    * `[:sycophant, :agent, :stop]` - Agent stops.
      Measurements: caller-provided (e.g. `%{duration: integer}`).
      Metadata: caller-provided (e.g. `%{reason: atom}`).

  ## Turn Events

    * `[:sycophant, :agent, :turn, :start]` - A turn begins.
      Measurements: `%{}`.
      Metadata: caller-provided (e.g. `%{turn_number: integer}`).

    * `[:sycophant, :agent, :turn, :stop]` - A turn completes.
      Measurements: caller-provided (e.g. `%{duration: integer, input_tokens: integer}`).
      Metadata: caller-provided.

  ## Tool Events

    * `[:sycophant, :agent, :tool, :start]` - Tool execution begins.
      Measurements: `%{}`.
      Metadata: caller-provided (e.g. `%{tool_name: string}`).

    * `[:sycophant, :agent, :tool, :stop]` - Tool execution completes.
      Measurements: caller-provided (e.g. `%{duration: integer}`).
      Metadata: caller-provided.

  ## Other Events

    * `[:sycophant, :agent, :error]` - An error occurs.
      Measurements: `%{}`.
      Metadata: caller-provided (e.g. `%{error: term}`).

    * `[:sycophant, :agent, :state_change]` - Agent state transition.
      Measurements: `%{}`.
      Metadata: `%{from_state: atom, to_state: atom}`.

  ## Attaching Handlers

      :telemetry.attach_many("agent-logger", Sycophant.Agent.Telemetry.events(), &handle_event/4, nil)
  """

  @prefix [:sycophant, :agent]

  @agent_start @prefix ++ [:start]
  @agent_stop @prefix ++ [:stop]
  @turn_start @prefix ++ [:turn, :start]
  @turn_stop @prefix ++ [:turn, :stop]
  @tool_start @prefix ++ [:tool, :start]
  @tool_stop @prefix ++ [:tool, :stop]
  @agent_error @prefix ++ [:error]
  @state_change @prefix ++ [:state_change]

  @doc "Returns the list of telemetry event names emitted by the agent."
  @spec events() :: [[atom(), ...]]
  def events do
    [
      @agent_start,
      @agent_stop,
      @turn_start,
      @turn_stop,
      @tool_start,
      @tool_stop,
      @agent_error,
      @state_change
    ]
  end

  @spec agent_start(map()) :: :ok
  def agent_start(metadata), do: :telemetry.execute(@agent_start, %{}, metadata)

  @spec agent_stop(map(), map()) :: :ok
  def agent_stop(measurements, metadata),
    do: :telemetry.execute(@agent_stop, measurements, metadata)

  @spec turn_start(map()) :: :ok
  def turn_start(metadata), do: :telemetry.execute(@turn_start, %{}, metadata)

  @spec turn_stop(map(), map()) :: :ok
  def turn_stop(measurements, metadata),
    do: :telemetry.execute(@turn_stop, measurements, metadata)

  @spec tool_start(map()) :: :ok
  def tool_start(metadata), do: :telemetry.execute(@tool_start, %{}, metadata)

  @spec tool_stop(map(), map()) :: :ok
  def tool_stop(measurements, metadata),
    do: :telemetry.execute(@tool_stop, measurements, metadata)

  @spec error(map()) :: :ok
  def error(metadata), do: :telemetry.execute(@agent_error, %{}, metadata)

  @spec state_change(atom(), atom()) :: :ok
  def state_change(from, to),
    do: :telemetry.execute(@state_change, %{}, %{from_state: from, to_state: to})
end
