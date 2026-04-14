# Architecture

Sycophant processes every LLM request through a deterministic pipeline that
handles model resolution, validation, encoding, transport, decoding, and
response enrichment.

## Request Pipeline

`Sycophant.Pipeline.call/2` executes these steps in order:

```
Messages + Options
       |
       v
  Model Resolution (LLMDB)
       |
       v
  Schema Normalization (Zoi/JSON Schema -> NormalizedSchema)
       |
       v
  Parameter Validation (Zoi schema per wire protocol)
       |
       v
  LLMDB Constraint Application (drop unsupported params)
       |
       v
  Credential Resolution (per-request > app config > env vars)
       |
       v
  Telemetry Span Start
       |
       v
  Wire Protocol Encoding (provider-specific JSON)
       |
       v
  HTTP Transport (Tesla, sync or streaming)
       |
       v
  Wire Protocol Decoding (back to Sycophant structs)
       |
       v
  Tool Execution Loop (up to max_steps if tools have functions)
       |
       v
  Cost Enrichment (LLMDB pricing data)
       |
       v
  Response Validation (JSON Schema check if generate_object)
       |
       v
  Context Attachment (conversation state for continuation)
       |
       v
  Telemetry Span Stop
       |
       v
  {:ok, Response} | {:error, Error}
```

Telemetry events only fire for requests that pass validation and credential
resolution. Invalid requests fail fast without emitting telemetry.

## Key Abstractions

### Wire Protocols

Each LLM provider speaks a different HTTP API. Wire protocol modules implement
the `Sycophant.WireProtocol` behaviour to handle encoding requests and decoding
responses in provider-specific formats.

Available wire protocols:

| Module | Provider | API Format |
|--------|----------|------------|
| `AnthropicMessages` | Anthropic | Messages API |
| `OpenAICompletions` | OpenAI, Azure, OpenRouter | Chat Completions |
| `OpenAIResponses` | OpenAI | Responses API |
| `GoogleGemini` | Google | Gemini API |
| `BedrockConverse` | AWS Bedrock | Converse API |

Each wire protocol declares a `@param_schema` via `Zoi.map`, composed from
shared parameter definitions (`ParamDefs.shared()`) plus wire-specific extras.
The pipeline validates request params against the resolved wire's schema.

### Model Resolver

`Sycophant.ModelResolver` takes a model spec string like
`"anthropic:claude-haiku-4-5-20251001"` and resolves it via LLMDB to:

- Provider atom (`:anthropic`)
- Model ID (`"claude-haiku-4-5-20251001"`)
- Base URL (`"https://api.anthropic.com"`)
- Wire protocol adapter module
- Model metadata (constraints, pricing, capabilities)

### Auth Strategies

Authentication is dispatched by provider atom through the `Sycophant.Auth`
registry:

| Strategy | Provider | Method |
|----------|----------|--------|
| `Auth.Bearer` | OpenAI, OpenRouter | `Authorization: Bearer` header |
| `Auth.Anthropic` | Anthropic | `x-api-key` header |
| `Auth.Google` | Google | `?key=` query parameter |
| `Auth.Bedrock` | AWS Bedrock | AWS SigV4 request signing |
| `Auth.Azure` | Azure | `api-key` header |

### Transport

`Sycophant.Transport` wraps Tesla to provide:

- Synchronous HTTP calls
- SSE streaming (OpenAI, Anthropic, Google, OpenRouter)
- Binary event-stream (AWS Bedrock)

The middleware stack is built dynamically from auth strategy and configuration.

### Context

`Sycophant.Context` is stored in `Response.context` after each request. It
carries the full message history, model, params, tools, and schema needed to
continue the conversation. Credentials are intentionally excluded and resolved
fresh on each call.

## Embedding Pipeline

Embeddings use a separate pipeline (`Sycophant.EmbeddingPipeline`) with its
own wire protocol behaviour (`Sycophant.EmbeddingWireProtocol`):

| Module | Provider |
|--------|----------|
| `OpenAIEmbed` | OpenAI |
| `BedrockEmbed` | AWS Bedrock |

## Module Organization

The codebase is organized into these functional areas:

- **Client API** -- `Sycophant`, `Request`, `Response`, `Context`
- **Messages** -- `Message`, `Message.Content.Text`, `Message.Content.Image`
- **Pipeline** -- `Pipeline`, `ModelResolver`, `ResponseValidator`, `ToolExecutor`
- **Wire Protocols** -- `WireProtocol` behaviour and provider implementations
- **Embeddings** -- `EmbeddingPipeline`, `EmbeddingRequest`, `EmbeddingResponse`
- **Auth** -- `Auth` dispatcher and strategy modules
- **Transport** -- `Transport`, `AWS.EventStream`
- **Telemetry** -- `Telemetry`, `OpenTelemetry`
- **Serialization** -- `Serializable` protocol and `Decoder`
- **Errors** -- `Error` hierarchy via Splode
- **Configuration** -- `Config`, `Credentials`, `ParamDefs`
