# Getting Started

This guide walks you through setting up Sycophant and making your first LLM
request.

## Installation

Add Sycophant to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:sycophant, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Credentials

Sycophant resolves credentials using a three-layer fallback:

1. **Per-request** -- passed directly in options
2. **Application config** -- from `config :sycophant, :providers`
3. **Environment variables** -- discovered automatically via LLMDB provider metadata

### Application Config

The most common approach. Add to `config/runtime.exs`:

```elixir
config :sycophant, :providers,
  openai: [api_key: System.get_env("OPENAI_API_KEY")],
  anthropic: [api_key: System.get_env("ANTHROPIC_API_KEY")],
  google: [api_key: System.get_env("GOOGLE_API_KEY")]
```

### Per-request Override

Useful for multi-tenant applications or testing:

```elixir
Sycophant.generate_text(messages,
  model: "openai:gpt-4o-mini",
  credentials: %{api_key: "sk-..."}
)
```

### AWS Bedrock

Bedrock uses AWS SigV4 signing. Credentials are resolved from the standard
AWS credential chain (environment variables, IAM role, etc.):

```elixir
config :sycophant, :providers,
  amazon_bedrock: [
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
    region: System.get_env("AWS_REGION", "us-east-1")
  ]
```

### Azure AI Foundry

Azure uses a deployment-based model where you deploy models to named endpoints:

```elixir
Sycophant.generate_text(messages,
  model: "azure:gpt-4o-mini",
  credentials: %{
    api_key: "your-azure-key",
    base_url: "https://your-resource.openai.azure.com",
    deployment_name: "my-gpt4o-deployment"
  }
)
```

## Your First Request

```elixir
alias Sycophant.Message

messages = [Message.user("What is the capital of France?")]

{:ok, response} = Sycophant.generate_text(messages, model: "openai:gpt-4o-mini")

IO.puts(response.text)
#=> "The capital of France is Paris."
```

## Model Identifiers

Models are specified as `"provider:model_id"` strings. The provider prefix
determines which wire protocol, authentication strategy, and base URL to use:

```elixir
# OpenAI
model: "openai:gpt-4o-mini"

# Anthropic
model: "anthropic:claude-haiku-4-5-20251001"

# Google Gemini
model: "google:gemini-2.0-flash"

# AWS Bedrock
model: "amazon_bedrock:anthropic.claude-3-5-haiku-20241022-v1:0"

# OpenRouter
model: "openrouter:meta-llama/llama-3.1-8b-instruct"
```

## LLM Parameters

Common parameters are passed as flat keyword options. Each wire protocol
declares its own param schema -- unsupported params for the target provider
are dropped with a warning log:

```elixir
Sycophant.generate_text(messages,
  model: "openai:gpt-4o-mini",
  temperature: 0.7,
  max_tokens: 500,
  top_p: 0.9
)
```

Wire-specific params work the same way:

```elixir
# OpenAI-specific
Sycophant.generate_text(messages,
  model: "openai:gpt-4o-mini",
  logprobs: true,
  seed: 42
)
```

## Multi-turn Conversations

Pass a previous `Response` with a new `Message` to continue the conversation.
Model, tools, and parameters carry over automatically:

```elixir
{:ok, r1} = Sycophant.generate_text(
  [Message.user("My name is Alice")],
  model: "openai:gpt-4o-mini"
)

{:ok, r2} = Sycophant.generate_text(r1, Message.user("What's my name?"))
IO.puts(r2.text)
#=> "Your name is Alice."
```

## Structured Output

Use `generate_object/3` with a Zoi schema to get validated structured data:

```elixir
schema = Zoi.object(%{
  name: Zoi.string(),
  age: Zoi.integer(),
  hobbies: Zoi.list(Zoi.string())
})

messages = [Message.user("Extract: Alice is 25 and likes hiking and painting")]

{:ok, response} = Sycophant.generate_object(messages, schema,
  model: "openai:gpt-4o-mini"
)

response.object
#=> %{name: "Alice", age: 25, hobbies: ["hiking", "painting"]}
```

## Streaming

Pass a callback function via the `:stream` option to receive chunks as they
arrive:

```elixir
Sycophant.generate_text(
  [Message.user("Write a haiku about Elixir")],
  model: "openai:gpt-4o-mini",
  stream: fn chunk -> IO.write(chunk.data) end
)
```

The callback receives `Sycophant.StreamChunk` structs. The final `Response`
is still returned as the function result.

## Next Steps

- [Architecture](architecture.md) -- understand the request pipeline
- [Tool Use](tool-use.md) -- auto-execute tools or handle calls manually
- [Error Handling](error-handling.md) -- pattern match on typed errors
- [Telemetry](telemetry.md) -- observe requests with telemetry and OpenTelemetry
- [Serialization](serialization.md) -- persist conversation state to a database
