<p align="center">
  <img src="logo.png" alt="Sycophant" width="256">
</p>

<h1 align="center">Sycophant</h1>

<p align="center">You are absolutely right if you use this lib!</p>

> **Warning:** Sycophant is under active development and the API is not yet
> stable. Expect breaking changes between versions until 1.0.

Sycophant abstracts the differences between OpenAI, Anthropic, Google Gemini,
AWS Bedrock, Azure AI Foundry, and OpenRouter behind a single composable API.
Provider-specific wire protocols, authentication, and parameter validation are
handled automatically based on the model identifier.

## Features

- **Multi-provider** -- OpenAI, Anthropic, Google Gemini, AWS Bedrock, Azure, OpenRouter
- **Text generation** -- synchronous and streaming responses
- **Structured output** -- validated against Zoi schemas
- **Tool use** -- auto-execution loop or manual handling
- **Embeddings** -- unified embedding API across providers
- **Multi-turn conversations** -- extract context from a response to continue
- **Automatic cost calculation** -- token costs from LLMDB pricing data
- **Telemetry** -- `:telemetry` events with optional OpenTelemetry bridge
- **Serialization** -- JSON round-trip for all core structs (database persistence)
- **Smart credentials** -- per-request, app config, or environment variable fallback

## Quick Start

```elixir
# Generate text
messages = [Sycophant.Message.user("What is the capital of France?")]

{:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
response.text
#=> "The capital of France is Paris."
```

```elixir
# Continue the conversation
alias Sycophant.Context

ctx = response.context |> Context.add(Sycophant.Message.user("Tell me more"))
{:ok, follow_up} = Sycophant.generate_text("openai:gpt-4o-mini", ctx)
```

```elixir
# Structured output with schema validation
schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
messages = [Sycophant.Message.user("Extract: John is 30 years old")]

{:ok, response} = Sycophant.generate_object("openai:gpt-4o-mini", messages, schema)
response.object
#=> %{name: "John", age: 30}
```

```elixir
# Streaming
Sycophant.generate_text("openai:gpt-4o-mini", messages,
  stream: fn chunk -> IO.write(chunk.data) end
)
```

```elixir
# Tool use with auto-execution
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Gets current weather for a city",
  parameters: Zoi.object(%{city: Zoi.string()}),
  function: fn %{"city" => city} -> "72F sunny in #{city}" end
}

Sycophant.generate_text("openai:gpt-4o-mini", messages,
  tools: [weather_tool]
)
```

```elixir
# Embeddings
request = %Sycophant.EmbeddingRequest{
  inputs: ["Hello world"],
  model: "amazon_bedrock:cohere.embed-english-v3"
}
{:ok, response} = Sycophant.embed(request)
```

## Installation

Add `sycophant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sycophant, github: "edlontech/sycophant", branch: "main"}
  ]
end
```

## Configuration

Credentials are resolved in order: per-request options, application config,
then environment variables.

```elixir
# config/runtime.exs
config :sycophant, :providers,
  openai: [api_key: System.get_env("OPENAI_API_KEY")],
  anthropic: [api_key: System.get_env("ANTHROPIC_API_KEY")],
  google: [api_key: System.get_env("GOOGLE_API_KEY")]
```

See the [Getting Started](guides/getting-started.md) guide for detailed setup
instructions and the full [documentation](https://hexdocs.pm/sycophant) for
API reference.

## Supported Providers

| Provider | Model Prefix | Auth | Wire Protocol |
|----------|-------------|------|---------------|
| OpenAI | `openai:` | Bearer token | Chat Completions / Responses |
| Anthropic | `anthropic:` | x-api-key | Messages |
| Google Gemini | `google:` | API key | Gemini |
| AWS Bedrock | `amazon_bedrock:` | AWS SigV4 | Converse |
| Azure AI Foundry | `azure:` | Bearer / API key | OpenAI Completions |
| OpenRouter | `openrouter:` | Bearer token | OpenAI Completions |

## Acknowledgements

Sycophant builds on the shoulders of great Elixir projects:

- [LLMDB](https://github.com/agentjido/llm_db) -- the model metadata database
  that powers model resolution, provider discovery, and pricing data.
- [Req LLM](https://github.com/agentjido/req_llm) -- a major source of
  inspiration for Sycophant's API design and multi-provider approach.

## License

See [LICENSE](LICENSE) for details.
