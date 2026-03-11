defmodule Sycophant.AgentTest do
  use ExUnit.Case, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Sycophant.Agent
  alias Sycophant.Agent.Callbacks
  alias Sycophant.Agent.Stats
  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Response
  alias Sycophant.Usage

  @model "anthropic:claude-haiku-4-5-20251001"

  defp build_response(text, opts \\ []) do
    context =
      Keyword.get(opts, :context, %Context{
        messages: [Message.user("hi"), Message.assistant(text)]
      })

    usage =
      Keyword.get(opts, :usage, %Usage{input_tokens: 10, output_tokens: 20, total_cost: 0.001})

    tool_calls = Keyword.get(opts, :tool_calls, [])
    finish_reason = Keyword.get(opts, :finish_reason, :stop)

    %Response{
      text: text,
      context: context,
      usage: usage,
      tool_calls: tool_calls,
      finish_reason: finish_reason
    }
  end

  describe "start_link/2 and lifecycle" do
    test "starts in idle state" do
      {:ok, agent} = Agent.start_link(@model)
      assert Agent.status(agent) == :idle
      Agent.stop(agent)
    end

    test "accepts existing context" do
      ctx = %Context{messages: [Message.system("You are helpful.")]}
      {:ok, agent} = Agent.start_link(@model, context: ctx)

      assert Agent.context(agent) == ctx
      Agent.stop(agent)
    end

    test "returns error for missing model" do
      assert {:error, _} = Agent.start_link(nil)
    end

    test "accepts name registration" do
      {:ok, _agent} = Agent.start_link(@model, name: :test_agent_name)
      assert Agent.status(:test_agent_name) == :idle
      Agent.stop(:test_agent_name)
    end
  end

  describe "chat/3" do
    test "sends message and returns response" do
      response = build_response("Hello!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:ok, %Response{text: "Hello!"}} = Agent.chat(agent, "Hi")
      Agent.stop(agent)
    end

    test "normalizes string input to user message" do
      response = build_response("Hello!")

      Sycophant
      |> expect(:generate_text, fn _model, %Context{messages: msgs}, _opts ->
        assert [%Message{role: :user, content: "Hi"}] = msgs
        {:ok, response}
      end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:ok, _} = Agent.chat(agent, "Hi")
      Agent.stop(agent)
    end

    test "accepts Message.t() input" do
      response = build_response("Hello!")
      msg = Message.user("Hi")

      Sycophant
      |> expect(:generate_text, fn _model, %Context{messages: msgs}, _opts ->
        assert [^msg] = msgs
        {:ok, response}
      end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:ok, _} = Agent.chat(agent, msg)
      Agent.stop(agent)
    end

    test "accepts list of messages" do
      response = build_response("Hello!")
      msgs = [Message.system("Be helpful"), Message.user("Hi")]

      Sycophant
      |> expect(:generate_text, fn _model, %Context{messages: ctx_msgs}, _opts ->
        assert ctx_msgs == msgs
        {:ok, response}
      end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:ok, _} = Agent.chat(agent, msgs)
      Agent.stop(agent)
    end

    test "updates context after successful response" do
      new_ctx = %Context{messages: [Message.user("Hi"), Message.assistant("Hello!")]}
      response = build_response("Hello!", context: new_ctx)

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      {:ok, agent} = Agent.start_link(@model)
      {:ok, _} = Agent.chat(agent, "Hi")

      assert Agent.context(agent) == new_ctx
      Agent.stop(agent)
    end

    test "returns {:error, :busy} when generating" do
      test_pid = self()

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts ->
        send(test_pid, :generating)
        Process.sleep(500)
        {:ok, build_response("Done")}
      end)

      {:ok, agent} = Agent.start_link(@model)

      Task.async(fn -> Agent.chat(agent, "Hi") end)
      assert_receive :generating, 1000

      assert {:error, :busy} = Agent.chat(agent, "Another", 100)
      Agent.stop(agent)
    end
  end

  describe "chat_async/2" do
    test "returns :ok immediately and delivers result via callback" do
      test_pid = self()
      response = build_response("Async hello!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      callbacks = Callbacks.new(on_response: fn result -> send(test_pid, {:response, result}) end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      assert :ok = Agent.chat_async(agent, "Hi")
      assert_receive {:response, {:ok, %Response{text: "Async hello!"}}}, 1000
      Agent.stop(agent)
    end

    test "returns {:error, :busy} when not idle" do
      test_pid = self()

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts ->
        send(test_pid, :generating)
        Process.sleep(500)
        {:ok, build_response("Done")}
      end)

      {:ok, agent} = Agent.start_link(@model)

      Agent.chat_async(agent, "Hi")
      assert_receive :generating, 1000

      assert {:error, :busy} = Agent.chat_async(agent, "Another")
      Agent.stop(agent)
    end
  end

  describe "statistics tracking" do
    test "records per-turn statistics" do
      usage = %Usage{input_tokens: 15, output_tokens: 25, total_cost: 0.002}
      response = build_response("Hello!", usage: usage)

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      {:ok, agent} = Agent.start_link(@model)
      {:ok, _} = Agent.chat(agent, "Hi")

      stats = Agent.stats(agent)
      assert stats.total_input_tokens == 15
      assert stats.total_output_tokens == 25
      assert stats.total_cost == 0.002
      assert Stats.turn_count(stats) == 1
      Agent.stop(agent)
    end
  end

  describe "error handling" do
    test "pipeline error returns error to sync caller" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:error, ^error} = Agent.chat(agent, "Hi")
      Agent.stop(agent)
    end

    test "agent recovers from error on next chat call" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      response = build_response("Recovered!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      {:ok, agent} = Agent.start_link(@model)
      {:error, _} = Agent.chat(agent, "Hi")
      assert {:ok, %Response{text: "Recovered!"}} = Agent.chat(agent, "Try again")
      Agent.stop(agent)
    end

    test "on_error :retry retries the call" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      response = build_response("Retried!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      callbacks = Callbacks.new(on_error: fn _error, _ctx -> :retry end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      assert {:ok, %Response{text: "Retried!"}} = Agent.chat(agent, "Hi")
      Agent.stop(agent)
    end

    test "on_error {:retry, delay} retries after delay" do
      test_pid = self()
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")
      response = build_response("Delayed retry!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts ->
        send(test_pid, {:retried_at, System.monotonic_time(:millisecond)})
        {:ok, response}
      end)

      callbacks =
        Callbacks.new(
          on_error: fn _error, _ctx ->
            send(test_pid, {:error_at, System.monotonic_time(:millisecond)})
            {:retry, 100}
          end
        )

      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)
      assert {:ok, %Response{text: "Delayed retry!"}} = Agent.chat(agent, "Hi", 5_000)

      assert_receive {:error_at, error_time}
      assert_receive {:retried_at, retry_time}
      assert retry_time - error_time >= 80

      Agent.stop(agent)
    end

    test "task crash transitions to error state" do
      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts ->
        raise "unexpected crash"
      end)

      {:ok, agent} = Agent.start_link(@model)
      assert {:error, %RuntimeError{message: msg}} = Agent.chat(agent, "Hi")
      assert msg =~ "Task crashed"
      assert Agent.status(agent) == :error
      Agent.stop(agent)
    end

    test "on_error :retry exhausts max_retries then returns error" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, 4, fn _model, _ctx, _opts -> {:error, error} end)

      callbacks = Callbacks.new(on_error: fn _error, _ctx -> :retry end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks, max_retries: 3)

      assert {:error, ^error} = Agent.chat(agent, "Hi")
      assert Agent.status(agent) == :error
      Agent.stop(agent)
    end

    test "retry count resets on new chat call" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")
      response = build_response("OK!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:ok, response} end)

      callbacks = Callbacks.new(on_error: fn _error, _ctx -> :retry end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks, max_retries: 3)

      assert {:error, _} = Agent.chat(agent, "Hi")
      assert {:ok, %Response{text: "OK!"}} = Agent.chat(agent, "Try again")
      Agent.stop(agent)
    end

    test "async error delivered via on_response when no on_error callback" do
      test_pid = self()
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)

      callbacks = Callbacks.new(on_response: fn result -> send(test_pid, {:result, result}) end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      Agent.chat_async(agent, "Hi")
      assert_receive {:result, {:error, ^error}}, 1000
      Agent.stop(agent)
    end

    test "on_error {:continue, msg} sends new message" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      response = build_response("Continued!")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, %Context{messages: msgs}, _opts ->
        assert List.last(msgs).content == "Please try differently"
        {:ok, response}
      end)

      callbacks =
        Callbacks.new(on_error: fn _error, _ctx -> {:continue, "Please try differently"} end)

      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      assert {:ok, %Response{text: "Continued!"}} = Agent.chat(agent, "Hi")
      Agent.stop(agent)
    end

    test "on_error {:stop, reason} transitions to completed" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)

      callbacks = Callbacks.new(on_error: fn _error, _ctx -> {:stop, :fatal} end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      assert {:error, {:stopped, :fatal}} = Agent.chat(agent, "Hi")
      assert Agent.status(agent) == :completed
      Agent.stop(agent)
    end

    test "returns {:error, :completed} when in completed state" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)

      callbacks = Callbacks.new(on_error: fn _error, _ctx -> {:stop, :done} end)
      {:ok, agent} = Agent.start_link(@model, callbacks: callbacks)

      {:error, _} = Agent.chat(agent, "Hi")
      assert {:error, :completed} = Agent.chat(agent, "More")
      Agent.stop(agent)
    end
  end

  describe "terminate telemetry" do
    test "emits agent_stop telemetry on stop" do
      test_pid = self()

      :telemetry.attach(
        "agent-stop-test",
        [:sycophant, :agent, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, agent} = Agent.start_link(@model)
      Agent.stop(agent)

      assert_receive {:telemetry, [:sycophant, :agent, :stop], measurements, metadata}, 1000
      assert is_map(measurements)
      assert metadata.reason == :normal

      :telemetry.detach("agent-stop-test")
    end
  end

  describe "streaming" do
    test "forwards stream chunks to callback" do
      test_pid = self()
      response = build_response("hello")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, opts ->
        stream_fn = opts[:stream]
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "hel"})
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "lo"})
        {:ok, response}
      end)

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn chunk -> send(test_pid, {:chunk, chunk.data}) end
        )

      {:ok, _response} = Agent.chat(agent, "hi")
      assert_receive {:chunk, "hel"}
      assert_receive {:chunk, "lo"}
      Agent.stop(agent)
    end

    test "reports :streaming status during generation" do
      test_pid = self()
      response = build_response("done")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, opts ->
        stream_fn = opts[:stream]
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "x"})
        send(test_pid, :stream_started)
        Process.sleep(200)
        {:ok, response}
      end)

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn _chunk -> :ok end
        )

      Agent.chat_async(agent, "hi")
      assert_receive :stream_started, 5000
      assert Agent.status(agent) == :streaming
      Agent.stop(agent)
    end

    test "stream callback stored separately from pipeline opts" do
      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn _chunk -> :ok end
        )

      assert Agent.status(agent) == :idle
      Agent.stop(agent)
    end

    test "streaming handles errors same as generating" do
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn _chunk -> :ok end
        )

      assert {:error, ^error} = Agent.chat(agent, "hi")
      assert Agent.status(agent) == :error
      Agent.stop(agent)
    end

    test "streaming returns {:error, :busy} for concurrent requests" do
      test_pid = self()
      response = build_response("done")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, opts ->
        stream_fn = opts[:stream]
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "x"})
        send(test_pid, :streaming)
        Process.sleep(500)
        {:ok, response}
      end)

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn _chunk -> :ok end
        )

      Task.async(fn -> Agent.chat(agent, "hi") end)
      assert_receive :streaming, 1000
      assert {:error, :busy} = Agent.chat(agent, "another", 100)
      Agent.stop(agent)
    end

    test "delayed retry works in streaming state" do
      test_pid = self()
      error = Sycophant.Error.Provider.ServerError.exception(status: 500, body: "boom")
      response = build_response("recovered")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, _opts -> {:error, error} end)
      |> expect(:generate_text, fn _model, _ctx, opts ->
        assert opts[:stream]
        send(test_pid, {:retried_at, System.monotonic_time(:millisecond)})
        {:ok, response}
      end)

      callbacks =
        Callbacks.new(
          on_error: fn _error, _ctx ->
            send(test_pid, {:error_at, System.monotonic_time(:millisecond)})
            {:retry, 50}
          end
        )

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn _chunk -> :ok end,
          callbacks: callbacks
        )

      assert {:ok, %Response{text: "recovered"}} = Agent.chat(agent, "hi", 5_000)
      assert_receive {:error_at, error_time}
      assert_receive {:retried_at, retry_time}
      assert retry_time - error_time >= 40
      Agent.stop(agent)
    end

    test "agent survives stream callback crash" do
      response = build_response("done")

      Sycophant
      |> expect(:generate_text, fn _model, _ctx, opts ->
        stream_fn = opts[:stream]
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "boom"})
        stream_fn.(%Sycophant.StreamChunk{type: :text_delta, data: "ok"})
        {:ok, response}
      end)

      {:ok, agent} =
        Agent.start_link(@model,
          stream: fn
            %{data: "boom"} -> raise "callback exploded"
            _chunk -> :ok
          end
        )

      assert {:ok, %Response{text: "done"}} = Agent.chat(agent, "hi")
      assert Agent.status(agent) == :idle
      Agent.stop(agent)
    end
  end

  describe "tool execution" do
    setup do
      tool = %Sycophant.Tool{
        name: "get_weather",
        description: "Get weather",
        parameters: %{},
        function: fn %{"city" => city} -> "#{city}: sunny" end
      }

      {:ok, tool: tool}
    end

    test "auto-executes tools and loops", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      counter = :counters.new(1, [:atomics])

      expect(Sycophant, :generate_text, 2, fn _, ctx, _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok, build_response("", tool_calls: [tc], context: ctx, finish_reason: :tool_use)}
        else
          {:ok, build_response("Paris is sunny", context: ctx)}
        end
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [tool])
      assert {:ok, %Response{text: "Paris is sunny"}} = Agent.chat(pid, "Weather in Paris?")
      Agent.stop(pid)
    end

    test "on_tool_call :reject skips tool", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}

      expect(Sycophant, :generate_text, fn _, _, _ ->
        {:ok,
         build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
      end)

      {:ok, pid} =
        Agent.start_link(@model,
          tools: [tool],
          callbacks: [on_tool_call: fn _tc -> :reject end]
        )

      {:ok, response} = Agent.chat(pid, "Weather?")
      assert response.tool_calls == [tc]
      Agent.stop(pid)
    end

    test "on_tool_call {:modify, tc} executes modified call", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      counter = :counters.new(1, [:atomics])

      expect(Sycophant, :generate_text, 2, fn _, _ctx, _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok,
           build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
        else
          {:ok, build_response("London is rainy", context: Context.new())}
        end
      end)

      {:ok, pid} =
        Agent.start_link(@model,
          tools: [tool],
          callbacks: [
            on_tool_call: fn tc ->
              {:modify, %{tc | arguments: %{"city" => "London"}}}
            end
          ]
        )

      {:ok, response} = Agent.chat(pid, "Weather?")
      assert response.text == "London is rainy"
      Agent.stop(pid)
    end

    test "on_max_steps :stop halts tool loop", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}

      expect(Sycophant, :generate_text, fn _, _ctx, _ ->
        {:ok,
         build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
      end)

      {:ok, pid} =
        Agent.start_link(@model,
          tools: [tool],
          max_steps: 1,
          callbacks: [on_max_steps: fn _steps, _ctx -> :stop end]
        )

      {:ok, _response} = Agent.chat(pid, "loop")
      assert Agent.status(pid) == :idle
      Agent.stop(pid)
    end

    test "tool execution error is handled gracefully", %{tool: _tool} do
      bad_tool = %Sycophant.Tool{
        name: "crasher",
        description: "Crashes",
        parameters: %{},
        function: fn _ -> raise "boom" end
      }

      tc = %Sycophant.ToolCall{id: "tc_1", name: "crasher", arguments: %{}}
      counter = :counters.new(1, [:atomics])

      expect(Sycophant, :generate_text, 2, fn _, _ctx, _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok,
           build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
        else
          {:ok, build_response("recovered", context: Context.new())}
        end
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [bad_tool])
      {:ok, response} = Agent.chat(pid, "crash")
      assert response.text == "recovered"
      Agent.stop(pid)
    end

    test "no tools with :function set passes through without execution" do
      tool_without_fn = %Sycophant.Tool{
        name: "manual_tool",
        description: "Manual",
        parameters: %{}
      }

      tc = %Sycophant.ToolCall{id: "tc_1", name: "manual_tool", arguments: %{}}

      expect(Sycophant, :generate_text, fn _, _, _ ->
        {:ok,
         build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [tool_without_fn])
      {:ok, response} = Agent.chat(pid, "use tool")
      assert response.tool_calls == [tc]
      assert Agent.status(pid) == :idle
      Agent.stop(pid)
    end

    test "emits tool telemetry events", %{tool: tool} do
      test_pid = self()
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      counter = :counters.new(1, [:atomics])

      :telemetry.attach(
        "tool-start-test",
        [:sycophant, :agent, :tool, :start],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "tool-stop-test",
        [:sycophant, :agent, :tool, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      expect(Sycophant, :generate_text, 2, fn _, _ctx, _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok,
           build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
        else
          {:ok, build_response("done", context: Context.new())}
        end
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [tool])
      {:ok, _} = Agent.chat(pid, "weather")

      assert_receive {:telemetry, [:sycophant, :agent, :tool, :start],
                      %{tool_name: "get_weather"}},
                     1000

      assert_receive {:telemetry, [:sycophant, :agent, :tool, :stop], %{duration: _},
                      %{tool_name: "get_weather"}},
                     1000

      :telemetry.detach("tool-start-test")
      :telemetry.detach("tool-stop-test")
      Agent.stop(pid)
    end

    test "max_steps default stops tool loop without callback", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}

      expect(Sycophant, :generate_text, fn _, _ctx, _ ->
        {:ok,
         build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [tool], max_steps: 1)
      {:ok, _response} = Agent.chat(pid, "loop")
      assert Agent.status(pid) == :idle
      Agent.stop(pid)
    end

    test "on_max_steps :continue allows tool loop to proceed", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      counter = :counters.new(1, [:atomics])

      expect(Sycophant, :generate_text, 3, fn _, _ctx, _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) <= 2 do
          {:ok,
           build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
        else
          {:ok, build_response("finally done", context: Context.new())}
        end
      end)

      {:ok, pid} =
        Agent.start_link(@model,
          tools: [tool],
          max_steps: 1,
          callbacks: [on_max_steps: fn _steps, _ctx -> :continue end]
        )

      {:ok, response} = Agent.chat(pid, "loop")
      assert response.text == "finally done"
      Agent.stop(pid)
    end

    test "current_step resets between conversations", %{tool: tool} do
      tc = %Sycophant.ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      counter = :counters.new(1, [:atomics])

      expect(Sycophant, :generate_text, 4, fn _, _ctx, _ ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        if count in [1, 3] do
          {:ok,
           build_response("", tool_calls: [tc], context: Context.new(), finish_reason: :tool_use)}
        else
          {:ok, build_response("answer #{count}", context: Context.new())}
        end
      end)

      {:ok, pid} = Agent.start_link(@model, tools: [tool], max_steps: 2)
      {:ok, r1} = Agent.chat(pid, "first")
      assert r1.text == "answer 2"

      {:ok, r2} = Agent.chat(pid, "second")
      assert r2.text == "answer 4"
      Agent.stop(pid)
    end
  end
end
