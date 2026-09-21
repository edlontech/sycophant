<p align="center">
  <img src="logo.png" alt="Sycophant" width="256">
</p>

<h1 align="center">Sycophant</h1>

<p align="center">You are absolutely right if you use this lib!</p>

> **Warning:** Sycophant is under active development and the API is not yet
> stable. Expect breaking changes between versions until 1.0.

Sycophant abstracts the differences between OpenAI, Anthropic, Google Gemini,
AWS Bedrock, Azure AI Foundry, OpenRouter, and GitHub Copilot behind a single
composable API. Provider-specific wire protocols, authentication, and
parameter validation are handled automatically based on the model identifier.

## Features

- **Multi-provider** -- OpenAI, Anthropic, Google Gemini, AWS Bedrock, Azure, OpenRouter, GitHub Copilot
- **Text generation** -- synchronous and streaming responses
- **Structured output** -- validated against Zoi or JSON Schema
- **Tool use** -- auto-execution loop or manual handling
- **Embeddings** -- unified embedding API across providers
- **Evaluation models** -- boolean, choice, and score judgments against an arbitrary state
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
# Tool use with auto-execution (Zoi schema -- atom keys in function)
weather_tool = %Sycophant.Tool{
  name: "get_weather",
  description: "Gets current weather for a city",
  parameters: Zoi.object(%{city: Zoi.string()}),
  function: fn %{city: city} -> "72F sunny in #{city}" end
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

```elixir
# Evaluation: score a state against typed questions
questions = %{
  department: %{
    type: :choice,
    instructions: "Which team should handle this ticket?",
    criteria: %{billing: "Billing and payments", support: "Technical support"}
  },
  urgent: %{type: :boolean, instructions: "Does this need immediate attention?"},
  severity: %{type: :score, instructions: "How severe is this?", criteria: ["minor", "moderate", "severe"]}
}

{:ok, response} = Sycophant.evaluate("typesafe:jev-latest", %{ticket: "Refund me"}, questions)
response.answers.department.value
#=> "billing"
response.answers.urgent.probability
#=> 0.93
```

Evaluation is not a chat API: no messages, no streaming. `:boolean` answers
expose only `probability` (no `value`); `:choice` answer values and
probabilities are always strings, since they name provider-defined options.
Answer keys mirror the caller's `questions` keys, but after a
`Sycophant.Serializable` round-trip they are always strings.

Two model routes are available:

- `typesafe:jev-latest` -- direct TypeSafe System One, needs `TYPESAFE_API_KEY`.
- `openrouter:typesafe/jev-1.13` -- via OpenRouter, needs `OPENROUTER_API_KEY`.
  Reports billed cost in `response.usage.total_cost`; the direct TypeSafe
  route leaves it `nil`.

## Installation

Add `sycophant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sycophant, "~> 0.5.1"} # x-release-please-version
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
| GitHub Copilot | `github_copilot:` | GitHub token (managed exchange) | OpenAI Completions |
| TypeSafe (evaluation only) | `typesafe:` | Bearer token | System One |

## Acknowledgements

Sycophant builds on:

- [LLMDB](https://github.com/agentjido/llm_db) -- the model metadata database
  that powers model resolution, provider discovery, and pricing data.
- [Req LLM](https://github.com/agentjido/req_llm) -- a major source of
  inspiration for Sycophant's API design and multi-provider approach.

## License

See [LICENSE](LICENSE) for details.
