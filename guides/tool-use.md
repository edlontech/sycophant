# Tool Use

Sycophant supports LLM tool use (function calling) with both automatic
execution and manual handling.

## Defining Tools

Tools are defined with a name, description, and a parameter schema. The
schema can be a Zoi schema or a JSON Schema map:

```elixir
# With Zoi schema
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: Zoi.object(%{
    city: Zoi.string(),
    unit: Zoi.enum(["celsius", "fahrenheit"])
  })
}

# With JSON Schema
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "city" => %{"type" => "string"},
      "unit" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
    },
    "required" => ["city", "unit"]
  }
}
```

## Auto-execution

When a tool has a `:function` set, Sycophant automatically executes it when
the LLM returns a tool call. The result is fed back to the LLM, which
continues generating. This loops up to `:max_steps` iterations (default 10):

```elixir
# Zoi-defined tools receive atom keys in function arguments
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: Zoi.object(%{city: Zoi.string()}),
  function: fn %{city: city} ->
    "72F and sunny in #{city}"
  end
}

# JSON Schema-defined tools receive string keys
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]},
  function: fn %{"city" => city} ->
    "72F and sunny in #{city}"
  end
}

messages = [Sycophant.Message.user("What's the weather in Paris?")]

{:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool]
)

response.text
#=> "The current weather in Paris is 72F and sunny."
```

The execution flow:

1. LLM receives the prompt and tool definitions
2. LLM decides to call `get_weather` with `%{"city" => "Paris"}`
3. Sycophant validates the arguments against the tool's schema
4. If using Zoi, keys are coerced to atoms; if JSON Schema, keys stay as strings
5. Sycophant executes the function and gets `"72F and sunny in Paris"`
6. Sycophant sends the result back to the LLM
7. LLM generates a final response incorporating the tool result

## Manual Handling

When a tool has no `:function`, tool calls are returned in `response.tool_calls`
for you to handle:

```elixir
search_tool = %Sycophant.Tool{
  name: "search",
  description: "Search the knowledge base",
  parameters: Zoi.object(%{query: Zoi.string()})
}

{:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [search_tool]
)

# Check if the LLM wants to call tools
if response.tool_calls != [] do
  Enum.each(response.tool_calls, fn tool_call ->
    IO.puts("Tool: #{tool_call.name}")
    IO.puts("Args: #{inspect(tool_call.arguments)}")
  end)
end
```

## Mixing Auto and Manual Tools

You can combine both approaches. Auto-executed tools loop internally while
manual tools are returned for external handling:

```elixir
auto_tool = %Sycophant.Tool{
  name: "calculate",
  description: "Evaluate a math expression",
  parameters: Zoi.object(%{expression: Zoi.string()}),
  function: fn %{"expression" => expr} -> "#{Code.eval_string(expr) |> elem(0)}" end
}

manual_tool = %Sycophant.Tool{
  name: "send_email",
  description: "Send an email to a user",
  parameters: Zoi.object(%{to: Zoi.string(), body: Zoi.string()})
}

Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [auto_tool, manual_tool],
  max_steps: 5
)
```

## Tool Parameters

Tool parameters can be defined using Zoi schemas or JSON Schema maps. Both
are converted to provider-specific JSON Schema format before being sent to
the LLM:

```elixir
# Zoi schema (recommended for Elixir-native development)
params = Zoi.object(%{
  query: Zoi.string(),
  limit: Zoi.integer() |> Zoi.default(10),
  filters: Zoi.object(%{
    category: Zoi.enum(["A", "B", "C"]),
    active: Zoi.boolean()
  })
})

# Equivalent JSON Schema
params = %{
  "type" => "object",
  "properties" => %{
    "query" => %{"type" => "string"},
    "limit" => %{"type" => "integer", "default" => 10},
    "filters" => %{
      "type" => "object",
      "properties" => %{
        "category" => %{"type" => "string", "enum" => ["A", "B", "C"]},
        "active" => %{"type" => "boolean"}
      },
      "required" => ["category", "active"]
    }
  },
  "required" => ["query", "filters"]
}
```

Tool arguments are validated against the schema before your function is
called. If validation fails, the LLM receives an error message and can
self-correct.

## Max Steps

The `:max_steps` option controls the maximum number of tool execution loop
iterations. This prevents infinite loops when the LLM keeps calling tools:

```elixir
Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool],
  max_steps: 3
)
```

## Disabling Auto-execution

Even when tools have a `:function` set, you can opt out of the auto-execution
loop by passing `auto_execute_tools: false`. The LLM's tool calls are returned
raw in `response.tool_calls` for you to inspect, dispatch, or confirm before
running:

```elixir
{:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool],
  auto_execute_tools: false
)

response.tool_calls
#=> [%Sycophant.ToolCall{name: "get_weather", arguments: %{"city" => "Paris"}, ...}]
```

This is useful for human-in-the-loop flows, audit logging, or running tool
calls in a different process/supervisor than the request pipeline.
