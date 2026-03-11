# Agent Mode

Sycophant provides a stateful agent that manages multi-turn LLM conversations
as a supervised process. The agent handles tool execution loops, error recovery,
streaming, and usage tracking automatically.

## Starting an Agent

An agent is a `GenStateMachine` process tied to a single model:

```elixir
{:ok, agent} = Sycophant.Agent.start_link("anthropic:claude-haiku-4-5-20251001")
```

Register it under a name for easy access:

```elixir
{:ok, agent} = Sycophant.Agent.start_link("openai:gpt-4o-mini", name: MyAgent)
```

Pass an initial context, tools, credentials, or any pipeline option:

```elixir
{:ok, agent} = Sycophant.Agent.start_link("anthropic:claude-haiku-4-5-20251001",
  context: %Sycophant.Context{system: "You are a helpful assistant."},
  tools: [weather_tool],
  credentials: %{api_key: "sk-..."},
  max_steps: 5,
  max_retries: 3
)
```

## Synchronous Chat

`chat/3` blocks until the LLM responds (and any tool loops complete):

```elixir
{:ok, response} = Sycophant.Agent.chat(agent, "What is the weather in Paris?")
IO.puts(response.text)
```

The agent preserves conversation context across calls:

```elixir
{:ok, _} = Sycophant.Agent.chat(agent, "My name is Alice.")
{:ok, r} = Sycophant.Agent.chat(agent, "What's my name?")
r.text #=> "Your name is Alice."
```

You can pass a custom timeout (default 30 seconds):

```elixir
{:ok, response} = Sycophant.Agent.chat(agent, "Write a long essay.", 60_000)
```

## Asynchronous Chat

`chat_async/2` returns immediately. The result is delivered through the
`on_response` callback:

```elixir
{:ok, agent} = Sycophant.Agent.start_link("openai:gpt-4o-mini",
  callbacks: %Sycophant.Agent.Callbacks{
    on_response: fn
      {:ok, response} -> IO.puts("Got: #{response.text}")
      {:error, error} -> IO.puts("Failed: #{inspect(error)}")
    end
  }
)

:ok = Sycophant.Agent.chat_async(agent, "Hello!")
```

Sending a message while the agent is busy returns `{:error, :busy}`.

## Streaming

Pass a `:stream` callback to receive chunks as they arrive:

```elixir
{:ok, agent} = Sycophant.Agent.start_link("openai:gpt-4o-mini",
  stream: fn chunk -> IO.write(chunk.data) end
)

{:ok, response} = Sycophant.Agent.chat(agent, "Write a haiku.")
```

The stream callback fires during generation. The final response is still
returned from `chat/3` or delivered via `on_response`. If the stream callback
raises, the exception is logged and the agent continues.

## Tool Execution

When tools with a `:function` are provided, the agent automatically executes
them and feeds results back to the LLM. This loops until the LLM stops
requesting tools or `max_steps` is reached:

```elixir
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: Zoi.object(%{city: Zoi.string()}),
  function: fn %{"city" => city} -> "72F and sunny in #{city}" end
}

{:ok, agent} = Sycophant.Agent.start_link("openai:gpt-4o-mini",
  tools: [weather_tool]
)

{:ok, response} = Sycophant.Agent.chat(agent, "What's the weather in Paris?")
response.text #=> "The current weather in Paris is 72F and sunny."
```

### Tool Call Callback

Use `on_tool_call` to approve, reject, or modify tool calls before execution:

```elixir
callbacks = %Sycophant.Agent.Callbacks{
  on_tool_call: fn tool_call ->
    if tool_call.name == "dangerous_tool" do
      :reject
    else
      :approve
    end
  end
}
```

The callback can return:
- `:approve` -- execute the tool call as-is
- `:reject` -- skip this tool call
- `{:modify, updated_tool_call}` -- execute with modified arguments

### Max Steps

When the tool loop reaches `max_steps`, the `on_max_steps` callback decides
what happens:

```elixir
callbacks = %Sycophant.Agent.Callbacks{
  on_max_steps: fn steps, _context ->
    if steps < 20, do: :continue, else: :stop
  end
}
```

Without an `on_max_steps` callback, the agent returns the last response.

## Error Handling and Retries

The `on_error` callback controls recovery when an LLM request fails:

```elixir
callbacks = %Sycophant.Agent.Callbacks{
  on_error: fn error, _context ->
    case error do
      %{class: :provider} -> :retry
      _ -> {:stop, :unrecoverable}
    end
  end
}
```

Return values:
- `:retry` -- retry immediately (up to `max_retries`)
- `{:retry, delay_ms}` -- retry after a delay
- `{:continue, input}` -- send a new message instead
- `{:stop, reason}` -- stop the agent, returns `{:error, {:stopped, reason}}`

Without an `on_error` callback, the agent transitions to the `:error` state
and returns the error. You can recover by sending a new `chat/3` call.

## Introspection

Query agent state at any time, even during generation:

```elixir
Sycophant.Agent.status(agent)   #=> :idle | :generating | :streaming | :tool_executing | :error | :completed
Sycophant.Agent.stats(agent)    #=> %Sycophant.Agent.Stats{...}
Sycophant.Agent.context(agent)  #=> %Sycophant.Context{...}
```

### Statistics

The stats struct accumulates token usage and cost across all turns:

```elixir
stats = Sycophant.Agent.stats(agent)
stats.total_input_tokens   #=> 1250
stats.total_output_tokens  #=> 340
stats.total_cost           #=> 0.0042

# Per-turn breakdown
for turn <- Sycophant.Agent.Stats.turns(stats) do
  IO.puts("#{turn.finish_reason}: #{turn.input_tokens}in / #{turn.output_tokens}out")
end
```

## Telemetry

The agent emits telemetry events under the `[:sycophant, :agent]` prefix:

| Event | When |
|-------|------|
| `[:sycophant, :agent, :start]` | Agent process starts |
| `[:sycophant, :agent, :stop]` | Agent process stops |
| `[:sycophant, :agent, :turn, :start]` | LLM request begins |
| `[:sycophant, :agent, :turn, :stop]` | LLM request completes |
| `[:sycophant, :agent, :tool, :start]` | Tool execution begins |
| `[:sycophant, :agent, :tool, :stop]` | Tool execution completes |
| `[:sycophant, :agent, :error]` | An error occurs |
| `[:sycophant, :agent, :state_change]` | State transition |

Attach handlers using `Sycophant.Agent.Telemetry.events/0`:

```elixir
:telemetry.attach_many(
  "agent-logger",
  Sycophant.Agent.Telemetry.events(),
  fn event, measurements, metadata, _config ->
    Logger.info("#{inspect(event)}: #{inspect(measurements)} #{inspect(metadata)}")
  end,
  nil
)
```

## Supervision

Agents are regular processes that can be added to a supervision tree:

```elixir
children = [
  {Sycophant.Agent, {"anthropic:claude-haiku-4-5-20251001", name: MyApp.Agent, tools: [weather_tool]}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Stop an agent gracefully with:

```elixir
Sycophant.Agent.stop(agent)
```

## State Machine

The agent transitions through these states:

```
idle --> generating/streaming --> tool_executing --> generating/streaming --> idle
                |                                                            ^
                +--> error (recoverable, send new chat to resume) -----------+
                +--> completed (terminal, agent stopped by callback)
```

- **idle** -- Ready for new messages
- **generating** -- Waiting for LLM response (no streaming)
- **streaming** -- Waiting for LLM response, forwarding chunks
- **tool_executing** -- Running tool functions and feeding results back
- **error** -- Last request failed; send a new `chat/3` to recover
- **completed** -- Agent stopped by an `on_error` callback returning `{:stop, reason}`
