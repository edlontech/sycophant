# Tool Use

Sycophant supports LLM tool use (function calling) with both automatic
execution and manual handling.

## Defining Tools

Tools are defined with a name, description, and Zoi parameter schema:

```elixir
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: Zoi.object(%{
    city: Zoi.string(),
    unit: Zoi.enum(["celsius", "fahrenheit"])
  })
}
```

## Auto-execution

When a tool has a `:function` set, Sycophant automatically executes it when
the LLM returns a tool call. The result is fed back to the LLM, which
continues generating. This loops up to `:max_steps` iterations (default 10):

```elixir
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: Zoi.object(%{city: Zoi.string()}),
  function: fn %{"city" => city} ->
    # Your implementation here
    "72F and sunny in #{city}"
  end
}

messages = [Sycophant.Message.user("What's the weather in Paris?")]

{:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool]
)

# The response contains the LLM's final answer incorporating the tool result
response.text
#=> "The current weather in Paris is 72F and sunny."
```

The execution flow:

1. LLM receives the prompt and tool definitions
2. LLM decides to call `get_weather` with `%{"city" => "Paris"}`
3. Sycophant executes the function and gets `"72F and sunny in Paris"`
4. Sycophant sends the result back to the LLM
5. LLM generates a final response incorporating the tool result

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

Tool parameters are defined using Zoi schemas, which are automatically
converted to provider-specific JSON Schema format by each wire protocol:

```elixir
params = Zoi.object(%{
  query: Zoi.string(),
  limit: Zoi.integer() |> Zoi.default(10),
  filters: Zoi.object(%{
    category: Zoi.enum(["A", "B", "C"]),
    active: Zoi.boolean()
  })
})
```

## Max Steps

The `:max_steps` option controls the maximum number of tool execution loop
iterations. This prevents infinite loops when the LLM keeps calling tools:

```elixir
Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool],
  max_steps: 3
)
```
