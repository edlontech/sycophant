# Serialization

Sycophant provides JSON round-trip serialization for all core structs via the
`Sycophant.Serializable` protocol. This enables persisting conversation state
to a database and restoring it later.

## Round-trip Example

```elixir
alias Sycophant.Serializable.Decoder

# After a conversation
{:ok, response} = Sycophant.generate_text(messages, model: "openai:gpt-4o-mini")

# Serialize to JSON
json = Decoder.encode(response)

# Store in database, cache, etc.
MyRepo.insert(%Conversation{state: json})

# Later, restore and continue
json = MyRepo.get(Conversation, id).state
restored = Decoder.decode(json)

{:ok, continued} = Sycophant.generate_text(restored, Message.user("Continue our chat"))
```

## Supported Structs

All core structs implement the `Sycophant.Serializable` protocol:

- `Response`
- `Context`
- `Message`
- `Message.Content.Text`
- `Message.Content.Image`
- `Tool`
- `ToolCall`
- `Usage`
- `Reasoning`
- `EmbeddingRequest`
- `EmbeddingResponse`
- `EmbeddingParams`

## Type Discriminators

Each serialized map includes a `"__type__"` key that identifies the struct
type for deserialization:

```elixir
Sycophant.Serializable.to_map(%Sycophant.Usage{input_tokens: 10, output_tokens: 25})
#=> %{"__type__" => "Usage", "input_tokens" => 10, "output_tokens" => 25}
```

## Tool Registry

Function references cannot be serialized to JSON. When decoding `Tool`
structs, pass a `:tool_registry` option to restore function references:

```elixir
registry = %{
  "get_weather" => &MyApp.Weather.get/1,
  "search" => &MyApp.Search.query/1
}

restored = Decoder.decode(json, tool_registry: registry)
```

Tools decoded without a registry will have `function: nil` and behave as
manual tools.

## Working with Maps

Use `from_map/2` when you already have parsed maps (e.g., from a JSON column
in your database):

```elixir
map = %{"__type__" => "Usage", "input_tokens" => 10, "output_tokens" => 25}
usage = Decoder.from_map(map)
#=> %Sycophant.Usage{input_tokens: 10, output_tokens: 25}
```
