defmodule Sycophant.Agent do
  @moduledoc """
  GenStateMachine-based agent that manages LLM conversations with tool execution,
  callbacks, statistics tracking, and telemetry.

  ## States

    * `:idle` - Ready to accept new messages
    * `:generating` - Waiting for LLM response
    * `:streaming` - Waiting for LLM response with stream forwarding
    * `:tool_executing` - Executing tool calls from LLM response
    * `:error` - Last request failed, recoverable
    * `:completed` - Agent stopped by callback, no further requests accepted

  ## Examples

      {:ok, agent} = Sycophant.Agent.start_link("anthropic:claude-haiku-4-5-20251001")
      {:ok, response} = Sycophant.Agent.chat(agent, "Hello!")
      Sycophant.Agent.stop(agent)
  """

  use GenStateMachine, callback_mode: :state_functions

  require Logger

  alias Sycophant.Agent.Callbacks
  alias Sycophant.Agent.State
  alias Sycophant.Agent.Stats
  alias Sycophant.Agent.Telemetry
  alias Sycophant.Context
  alias Sycophant.Message

  @type agent :: GenStateMachine.server_ref()

  # -- Public API --

  @doc "Starts an agent process linked to the caller."
  @spec start_link(String.t() | nil, keyword()) :: GenStateMachine.on_start()
  def start_link(model, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    {context, opts} = Keyword.pop(opts, :context, %Context{})
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {credentials, opts} = Keyword.pop(opts, :credentials)
    {callbacks, opts} = Keyword.pop(opts, :callbacks, %Callbacks{})
    {max_steps, opts} = Keyword.pop(opts, :max_steps, 10)
    {max_retries, opts} = Keyword.pop(opts, :max_retries, 3)
    {stream, opts} = Keyword.pop(opts, :stream)

    callbacks = normalize_callbacks(callbacks)

    pipeline_opts =
      opts
      |> maybe_put(:tools, tools)
      |> maybe_put(:credentials, credentials)
      |> Keyword.put(:max_steps, 0)

    callers = [self() | Process.get(:"$callers", [])]

    init_opts = [
      model: model,
      context: %{context | tools: tools},
      opts: pipeline_opts,
      callbacks: callbacks,
      max_steps: max_steps,
      max_retries: max_retries,
      stream: stream,
      callers: callers
    ]

    case State.new(init_opts) do
      {:ok, _} ->
        gen_opts = if name, do: [name: name], else: []
        GenStateMachine.start_link(__MODULE__, init_opts, gen_opts)

      {:error, _} = error ->
        error
    end
  end

  @doc "Stops the agent process."
  @spec stop(agent(), term()) :: :ok
  def stop(agent, reason \\ :normal) do
    GenStateMachine.stop(agent, reason)
  end

  @doc "Sends a message and waits synchronously for the response."
  @spec chat(agent(), String.t() | Message.t() | [Message.t()], timeout()) ::
          {:ok, Sycophant.Response.t()} | {:error, term()}
  def chat(agent, input, timeout \\ 30_000) do
    GenStateMachine.call(agent, {:chat, normalize_input(input)}, timeout)
  end

  @doc "Sends a message asynchronously; response delivered via `on_response` callback."
  @spec chat_async(agent(), String.t() | Message.t() | [Message.t()]) :: :ok | {:error, term()}
  def chat_async(agent, input) do
    GenStateMachine.call(agent, {:chat_async, normalize_input(input)})
  end

  @doc "Returns the current state of the agent."
  @spec status(agent()) :: atom()
  def status(agent), do: GenStateMachine.call(agent, :status)

  @doc "Returns accumulated statistics for all turns."
  @spec stats(agent()) :: Stats.t()
  def stats(agent), do: GenStateMachine.call(agent, :stats)

  @doc "Returns the current conversation context."
  @spec context(agent()) :: Context.t()
  def context(agent), do: GenStateMachine.call(agent, :context)

  # -- GenStateMachine callbacks --

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    callers = Keyword.get(opts, :callers, [])
    Process.put(:"$callers", callers)

    case State.new(opts) do
      {:ok, data} ->
        Telemetry.agent_start(%{model: data.model})
        {:ok, :idle, data}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # -- Introspection (handled in all states) --

  @doc false
  def idle(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}

  def idle({:call, from}, :status, data), do: {:keep_state, data, [{:reply, from, :idle}]}
  def idle({:call, from}, :stats, data), do: {:keep_state, data, [{:reply, from, data.stats}]}
  def idle({:call, from}, :context, data), do: {:keep_state, data, [{:reply, from, data.context}]}

  def idle({:call, from}, {:chat, messages}, data) do
    target = target_state(data)
    Telemetry.state_change(:idle, target)
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    data = append_messages_and_spawn(data, messages, from)
    {:next_state, target, data}
  end

  def idle({:call, from}, {:chat_async, messages}, data) do
    target = target_state(data)
    Telemetry.state_change(:idle, target)
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    data = append_messages_and_spawn(data, messages, nil)
    {:next_state, target, data, [{:reply, from, :ok}]}
  end

  # -- Generating state --

  @doc false
  def generating({:call, from}, :status, data),
    do: {:keep_state, data, [{:reply, from, :generating}]}

  def generating({:call, from}, :stats, data),
    do: {:keep_state, data, [{:reply, from, data.stats}]}

  def generating({:call, from}, :context, data),
    do: {:keep_state, data, [{:reply, from, data.context}]}

  def generating({:call, from}, {:chat, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def generating({:call, from}, {:chat_async, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def generating(:info, {ref, {:ok, response}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    handle_success(response, data, :generating)
  end

  def generating(:info, {ref, {:error, error}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    handle_error(error, data, :generating)
  end

  def generating(:info, {:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = data) do
    error = RuntimeError.exception("Task crashed: #{inspect(reason)}")
    handle_error(error, data, :generating)
  end

  def generating(:info, {:EXIT, _pid, _reason}, data) do
    {:keep_state, data}
  end

  def generating(:state_timeout, :delayed_retry, data) do
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    ref = spawn_pipeline(data.model, data.context, pipeline_opts(data))
    {:keep_state, %{data | task_ref: ref}}
  end

  # -- Streaming state --

  @doc false
  def streaming({:call, from}, :status, data),
    do: {:keep_state, data, [{:reply, from, :streaming}]}

  def streaming({:call, from}, :stats, data),
    do: {:keep_state, data, [{:reply, from, data.stats}]}

  def streaming({:call, from}, :context, data),
    do: {:keep_state, data, [{:reply, from, data.context}]}

  def streaming({:call, from}, {:chat, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def streaming({:call, from}, {:chat_async, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def streaming(:info, {:stream_chunk, chunk}, data) do
    try do
      case data.stream do
        {acc, callback} when is_function(callback, 2) ->
          new_acc = callback.(chunk, acc)
          {:keep_state, %{data | stream: {new_acc, callback}}}

        callback when is_function(callback, 1) ->
          callback.(chunk)
          {:keep_state, data}
      end
    rescue
      e ->
        Logger.warning("Stream callback raised: #{Exception.message(e)}")
        {:keep_state, data}
    end
  end

  def streaming(:info, {ref, {:ok, response}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    handle_success(response, data, :streaming)
  end

  def streaming(:info, {ref, {:error, error}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    handle_error(error, data, :streaming)
  end

  def streaming(:info, {:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = data) do
    error = RuntimeError.exception("Task crashed: #{inspect(reason)}")
    handle_error(error, data, :streaming)
  end

  def streaming(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}

  def streaming(:state_timeout, :delayed_retry, data) do
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    ref = spawn_pipeline(data.model, data.context, pipeline_opts(data))
    {:keep_state, %{data | task_ref: ref}}
  end

  # -- Error state --

  @doc false
  def error(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}

  def error({:call, from}, :status, data), do: {:keep_state, data, [{:reply, from, :error}]}
  def error({:call, from}, :stats, data), do: {:keep_state, data, [{:reply, from, data.stats}]}

  def error({:call, from}, :context, data),
    do: {:keep_state, data, [{:reply, from, data.context}]}

  def error({:call, from}, {:chat, messages}, data) do
    target = target_state(data)
    Telemetry.state_change(:error, target)
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    data = %{data | last_error: nil}
    data = append_messages_and_spawn(data, messages, from)
    {:next_state, target, data}
  end

  def error({:call, from}, {:chat_async, messages}, data) do
    target = target_state(data)
    Telemetry.state_change(:error, target)
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    data = %{data | last_error: nil}
    data = append_messages_and_spawn(data, messages, nil)
    {:next_state, target, data, [{:reply, from, :ok}]}
  end

  # -- Completed state --

  @doc false
  def completed(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}

  def completed({:call, from}, :status, data),
    do: {:keep_state, data, [{:reply, from, :completed}]}

  def completed({:call, from}, :stats, data),
    do: {:keep_state, data, [{:reply, from, data.stats}]}

  def completed({:call, from}, :context, data),
    do: {:keep_state, data, [{:reply, from, data.context}]}

  def completed({:call, from}, {:chat, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :completed}}]}

  def completed({:call, from}, {:chat_async, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :completed}}]}

  @impl true
  def terminate(reason, _state, data) do
    Telemetry.agent_stop(
      %{
        total_input_tokens: data.stats.total_input_tokens,
        total_output_tokens: data.stats.total_output_tokens,
        total_cost: data.stats.total_cost,
        turns: Stats.turn_count(data.stats)
      },
      %{reason: reason, model: data.model}
    )
  end

  # -- Internal helpers --

  defp normalize_input(text) when is_binary(text), do: [Message.user(text)]
  defp normalize_input(%Message{} = msg), do: [msg]
  defp normalize_input(messages) when is_list(messages), do: messages

  defp normalize_callbacks(%Callbacks{} = cb), do: cb
  defp normalize_callbacks(opts) when is_list(opts), do: Callbacks.new(opts)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp target_state(%{stream: nil}), do: :generating
  defp target_state(%{stream: _}), do: :streaming

  defp pipeline_opts(%{stream: nil, opts: opts}), do: opts

  defp pipeline_opts(%{stream: _, opts: opts}) do
    agent = self()
    internal = {nil, fn chunk, _acc -> send(agent, {:stream_chunk, chunk}) end}
    Keyword.put(opts, :stream, internal)
  end

  defp append_messages_and_spawn(data, messages, from) do
    context = Context.add(data.context, messages)
    ref = spawn_pipeline(data.model, context, pipeline_opts(data))
    %{data | context: context, from: from, task_ref: ref, retry_count: 0}
  end

  defp spawn_pipeline(model, context, opts) do
    task = Task.async(fn -> Sycophant.generate_text(model, context, opts) end)
    task.ref
  end

  # -- Tool executing state --

  @doc false
  def tool_executing(:internal, {:execute_tools, response, tool_map}, data) do
    on_tool_call = data.callbacks.on_tool_call

    {results, all_rejected} =
      Enum.reduce(response.tool_calls, {[], true}, fn tc, {acc, all_rej} ->
        case apply_tool_call_callback(on_tool_call, tc) do
          {:reject, _} ->
            {acc, all_rej}

          {:execute, effective_tc} ->
            result = execute_tool(tool_map, effective_tc)
            msg = Message.tool_result(effective_tc, result)
            {[msg | acc], false}
        end
      end)

    if all_rejected do
      Telemetry.state_change(:tool_executing, :idle)
      reply_or_callback(data, {:ok, response}, :idle)
    else
      tool_results = Enum.reverse(results)
      context = Context.add(data.context, tool_results)
      data = %{data | context: context, current_step: data.current_step + 1}

      if data.current_step >= data.max_steps do
        handle_max_steps(response, data)
      else
        target = target_state(data)
        Telemetry.state_change(:tool_executing, target)
        Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
        ref = spawn_pipeline(data.model, data.context, pipeline_opts(data))
        {:next_state, target, %{data | task_ref: ref}}
      end
    end
  end

  def tool_executing({:call, from}, :status, data),
    do: {:keep_state, data, [{:reply, from, :tool_executing}]}

  def tool_executing({:call, from}, :stats, data),
    do: {:keep_state, data, [{:reply, from, data.stats}]}

  def tool_executing({:call, from}, :context, data),
    do: {:keep_state, data, [{:reply, from, data.context}]}

  def tool_executing({:call, from}, {:chat, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def tool_executing({:call, from}, {:chat_async, _messages}, data),
    do: {:keep_state, data, [{:reply, from, {:error, :busy}}]}

  def tool_executing(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}

  defp handle_success(response, data, from_state) do
    Telemetry.turn_stop(
      %{
        input_tokens: (response.usage && response.usage.input_tokens) || 0,
        output_tokens: (response.usage && response.usage.output_tokens) || 0
      },
      %{finish_reason: response.finish_reason}
    )

    new_stats = Stats.record_turn(data.stats, response.usage, response.finish_reason)
    data = %{data | context: response.context, stats: new_stats}

    tool_map = build_tool_map(data.opts[:tools] || [])

    if has_executable_tool_calls?(response, tool_map) do
      Telemetry.state_change(from_state, :tool_executing)

      {:next_state, :tool_executing, data,
       [{:next_event, :internal, {:execute_tools, response, tool_map}}]}
    else
      Telemetry.state_change(from_state, :idle)
      reply_or_callback(data, {:ok, response}, :idle)
    end
  end

  defp has_executable_tool_calls?(%{tool_calls: tcs}, tool_map)
       when is_list(tcs) and tcs != [] do
    Enum.any?(tcs, fn tc -> Map.has_key?(tool_map, tc.name) end)
  end

  defp has_executable_tool_calls?(_, _), do: false

  defp build_tool_map(tools) do
    tools
    |> Enum.filter(& &1.function)
    |> Map.new(&{&1.name, &1})
  end

  defp apply_tool_call_callback(nil, tc), do: {:execute, tc}

  defp apply_tool_call_callback(callback, tc) do
    case callback.(tc) do
      :approve -> {:execute, tc}
      :reject -> {:reject, tc}
      {:modify, modified_tc} -> {:execute, modified_tc}
    end
  end

  defp execute_tool(tool_map, tc) do
    Telemetry.tool_start(%{tool_name: tc.name})
    start_time = System.monotonic_time()

    result =
      try do
        case Map.get(tool_map, tc.name) do
          nil ->
            "Error: unknown tool #{tc.name}"

          tool ->
            case validate_tool_args(tool.resolved_schema, tc.arguments) do
              {:ok, args} -> tool.function.(args) |> to_string()
              {:error, msg} -> "Validation error: #{msg}"
            end
        end
      rescue
        e -> "Error: #{Exception.message(e)}"
      end

    duration = System.monotonic_time() - start_time
    Telemetry.tool_stop(%{duration: duration}, %{tool_name: tc.name})
    result
  end

  defp validate_tool_args(nil, arguments), do: {:ok, arguments}

  defp validate_tool_args(schema, arguments) do
    case Sycophant.Schema.Validator.validate(schema, arguments) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp handle_max_steps(response, data) do
    case data.callbacks.on_max_steps do
      nil ->
        Telemetry.state_change(:tool_executing, :idle)
        reply_or_callback(data, {:ok, response}, :idle)

      callback ->
        case callback.(data.current_step, data.context) do
          :continue ->
            target = target_state(data)
            Telemetry.state_change(:tool_executing, target)
            Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
            ref = spawn_pipeline(data.model, data.context, pipeline_opts(data))
            {:next_state, target, %{data | task_ref: ref}}

          :stop ->
            Telemetry.state_change(:tool_executing, :idle)
            reply_or_callback(data, {:ok, response}, :idle)
        end
    end
  end

  defp handle_error(error, data, from_state) do
    Telemetry.error(%{error: error})
    data = %{data | last_error: error}

    case data.callbacks.on_error do
      nil ->
        Telemetry.state_change(from_state, :error)
        reply_or_callback(data, {:error, error}, :error)

      callback ->
        dispatch_error_callback(callback, error, data, from_state)
    end
  end

  defp dispatch_error_callback(callback, error, data, from_state) do
    case callback.(error, data.context) do
      retry when retry == :retry or (is_tuple(retry) and elem(retry, 0) == :retry) ->
        if data.retry_count >= data.max_retries do
          Telemetry.state_change(from_state, :error)
          reply_or_callback(data, {:error, error}, :error)
        else
          data = %{data | retry_count: data.retry_count + 1}
          dispatch_retry(retry, data)
        end

      {:continue, input} ->
        messages = normalize_input(input)
        context = Context.add(data.context, messages)
        Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
        ref = spawn_pipeline(data.model, context, pipeline_opts(data))
        {:keep_state, %{data | context: context, task_ref: ref}}

      {:stop, reason} ->
        Telemetry.state_change(from_state, :completed)
        reply_or_callback(data, {:error, {:stopped, reason}}, :completed)
    end
  end

  defp dispatch_retry(:retry, data) do
    Telemetry.turn_start(%{turn_number: Stats.turn_count(data.stats) + 1})
    ref = spawn_pipeline(data.model, data.context, pipeline_opts(data))
    {:keep_state, %{data | task_ref: ref}}
  end

  defp dispatch_retry({:retry, delay}, data) do
    {:keep_state, data, [{:state_timeout, delay, :delayed_retry}]}
  end

  defp reply_or_callback(data, result, next_state) do
    from = data.from
    data = %{data | task_ref: nil, from: nil, current_step: 0}

    if from do
      {:next_state, next_state, data, [{:reply, from, result}]}
    else
      invoke_on_response(data.callbacks, result)
      {:next_state, next_state, data}
    end
  end

  defp invoke_on_response(%{on_response: nil}, _result), do: :ok
  defp invoke_on_response(%{on_response: callback}, result), do: callback.(result)
end
