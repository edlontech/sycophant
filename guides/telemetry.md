# Telemetry

Sycophant emits `:telemetry` events at key points in the request lifecycle,
following the standard span pattern. An optional OpenTelemetry bridge translates
these events into OTel spans with GenAI semantic conventions.

## Events

### Request Lifecycle

- `[:sycophant, :request, :start]` -- request begins
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{model, provider, wire_protocol, has_tools?, has_stream?, temperature, top_p, top_k, max_tokens}`

- `[:sycophant, :request, :stop]` -- request succeeds
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: start metadata merged with `%{duration, usage, response_model, response_id, finish_reason}`
  - Usage includes token counts, cache token counts, and cost fields

- `[:sycophant, :request, :error]` -- request fails
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: start metadata merged with `%{error, error_class}`

### Streaming

- `[:sycophant, :stream, :chunk]` -- individual stream chunk received
  - Measurements: `%{}`
  - Metadata: `%{chunk_type: atom}`

### Embeddings

- `[:sycophant, :embedding, :start]` -- embedding request begins
- `[:sycophant, :embedding, :stop]` -- embedding request succeeds
- `[:sycophant, :embedding, :error]` -- embedding request fails

## Attaching Handlers

```elixir
:telemetry.attach_many(
  "my-sycophant-handler",
  Sycophant.Telemetry.events(),
  &handle_event/4,
  nil
)

defp handle_event([:sycophant, :request, :stop], measurements, metadata, _config) do
  Logger.info(
    "LLM request to #{metadata.model} took #{measurements.duration} " <>
    "and used #{metadata.usage[:total_tokens]} tokens"
  )
end
```

## Telemetry Placement

Telemetry events only fire for requests that pass parameter validation and
credential resolution. Invalid requests fail fast without emitting events.
This means your telemetry handlers only see real API calls, not configuration
errors.

## Usage Metadata

The `usage` field in stop metadata contains:

| Key | Description |
|-----|-------------|
| `:input_tokens` | Tokens in the prompt |
| `:output_tokens` | Tokens in the completion |
| `:total_tokens` | Sum of input and output (computed) |
| `:cache_creation_input_tokens` | Tokens written to provider cache |
| `:cache_read_input_tokens` | Tokens read from provider cache |
| `:reasoning_tokens` | Internal reasoning tokens (thinking models) |
| `:input_cost` | Cost of input tokens (from LLMDB pricing) |
| `:output_cost` | Cost of output tokens |
| `:cache_read_cost` | Cost of cache read tokens |
| `:cache_write_cost` | Cost of cache creation tokens |
| `:reasoning_cost` | Cost of reasoning tokens |
| `:total_cost` | Sum of all cost components |
| `:pricing` | Full pricing metadata as a plain map (see [Pricing guide](pricing.md)) |

## OpenTelemetry Integration

Sycophant includes an optional OpenTelemetry bridge that creates OTel spans
from telemetry events, following the
[GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/).

### Setup

Add the optional dependency to your `mix.exs`:

```elixir
{:opentelemetry_telemetry, "~> 1.1"}
```

Then call setup in your application startup:

```elixir
# In your Application.start/2
Sycophant.OpenTelemetry.setup()
```

### Span Attributes

Start attributes follow GenAI conventions:

| Attribute | Source |
|-----------|--------|
| `gen_ai.operation.name` | `"chat"` or `"embeddings"` |
| `gen_ai.provider.name` | Provider atom as string |
| `gen_ai.request.model` | Requested model identifier |
| `gen_ai.request.temperature` | Temperature parameter |
| `gen_ai.request.top_p` | Top-p parameter |
| `gen_ai.request.top_k` | Top-k parameter |
| `gen_ai.request.max_tokens` | Max tokens parameter |

Stop attributes:

| Attribute | Source |
|-----------|--------|
| `gen_ai.usage.input_tokens` | Input token count |
| `gen_ai.usage.output_tokens` | Output token count |
| `gen_ai.usage.cache_creation.input_tokens` | Cache creation tokens |
| `gen_ai.usage.cache_read.input_tokens` | Cache read tokens |
| `gen_ai.response.model` | Actual model used |
| `gen_ai.response.id` | Provider response ID |
| `gen_ai.response.finish_reasons` | Finish reason(s) |

### Custom Attributes

Pass an `attribute_mapper` function to enrich spans with application-specific
attributes:

```elixir
Sycophant.OpenTelemetry.setup(
  attribute_mapper: fn metadata ->
    [
      {"app.tenant_id", metadata[:tenant_id]},
      {"app.feature", metadata[:feature]}
    ]
  end
)
```

### Span Propagation

The OTel bridge creates child spans of whatever trace context exists in the
calling process. If your Phoenix controller or LiveView already has an active
span, Sycophant spans will appear as children automatically.

### Teardown

```elixir
Sycophant.OpenTelemetry.teardown()
```
