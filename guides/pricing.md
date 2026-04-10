# Pricing and Cost Tracking

Sycophant automatically calculates per-request costs using model pricing data
from LLMDB. Costs are attached to the `Usage` struct on every response.

## How It Works

After each request, the pipeline:

1. Reads the model's pricing metadata from LLMDB
2. Matches token counts against pricing components by ID
3. Computes costs using each component's rate and unit size
4. Attaches the results (and the full pricing reference) to `response.usage`

No configuration is needed. If LLMDB has pricing data for the model, costs
are calculated automatically.

## Reading Costs

```elixir
{:ok, response} = Sycophant.generate_text("anthropic:claude-sonnet-4-20250514",
  messages: [%{role: "user", content: "Hello"}]
)

response.usage.input_cost      #=> 0.003
response.usage.output_cost     #=> 0.015
response.usage.total_cost      #=> 0.018
```

All cost fields are in USD. They are `nil` when the model has no pricing data
or when the corresponding token count is `nil`.

## Cost Fields

| Field | Description |
|-------|-------------|
| `input_cost` | Cost of input/prompt tokens |
| `output_cost` | Cost of output/completion tokens |
| `cache_read_cost` | Cost of tokens read from provider cache |
| `cache_write_cost` | Cost of tokens written to provider cache |
| `reasoning_cost` | Cost of reasoning tokens (o-series, thinking models) |
| `total_cost` | Sum of all non-nil cost components |

## Token Fields

| Field | Description |
|-------|-------------|
| `input_tokens` | Tokens in the prompt |
| `output_tokens` | Tokens in the completion |
| `cache_creation_input_tokens` | Tokens written to provider cache |
| `cache_read_input_tokens` | Tokens read from provider cache |
| `reasoning_tokens` | Internal reasoning tokens (o-series, thinking models) |

## Pricing Reference

The full pricing metadata from LLMDB is attached to `response.usage.pricing`.
This includes all pricing components for the model, not just the token ones
used for automatic cost calculation.

```elixir
response.usage.pricing
#=> %Sycophant.Pricing{
#     currency: "USD",
#     components: [
#       %Sycophant.Pricing.Component{id: "token.input", kind: "token", per: 1000000, rate: 3.0, ...},
#       %Sycophant.Pricing.Component{id: "token.output", kind: "token", per: 1000000, rate: 15.0, ...},
#       %Sycophant.Pricing.Component{id: "tool.web_search", kind: "tool", per: 1000, rate: 10.0, ...},
#       ...
#     ]
#   }
```

### Component Kinds

LLMDB pricing components fall into four kinds:

| Kind | Description | Examples |
|------|-------------|---------|
| `"token"` | Per-token rates | `token.input`, `token.output`, `token.cache_read`, `token.reasoning` |
| `"tool"` | Per-call rates for built-in tools | `tool.web_search`, `tool.file_search`, `tool.code_interpreter` |
| `"image"` | Per-image rates by size/quality | `image.1024x1024`, `image.generated` |
| `"storage"` | Per-unit storage rates | `storage.file_search` |

Only `"token"` components are used for automatic cost calculation. Tool, image,
and storage components are attached as reference data for callers who need them.

### Looking Up Components

```elixir
alias Sycophant.Pricing

pricing = response.usage.pricing
Pricing.find_component(pricing, "token.input")
#=> %Pricing.Component{id: "token.input", kind: "token", per: 1000000, rate: 3.0, ...}

Pricing.find_component(pricing, "tool.web_search")
#=> %Pricing.Component{id: "tool.web_search", kind: "tool", per: 1000, rate: 10.0, tool: "web_search", ...}
```

## Reasoning Tokens

Models with reasoning capabilities (OpenAI o-series, Google Gemini with
thinking) report reasoning tokens separately. These are internal tokens the
model uses for chain-of-thought processing.

```elixir
{:ok, response} = Sycophant.generate_text("openai:o3",
  messages: [%{role: "user", content: "Solve this step by step: ..."}]
)

response.usage.reasoning_tokens  #=> 1250
response.usage.reasoning_cost    #=> 0.000625
```

Reasoning tokens are extracted from:
- OpenAI Completions: `completion_tokens_details.reasoning_tokens`
- OpenAI Responses: `output_tokens_details.reasoning_tokens`
- Google Gemini: `usageMetadata.thoughtsTokenCount`

Anthropic and Bedrock do not report reasoning tokens separately.

## Agent Cost Tracking

When using agent mode, `Agent.Stats` accumulates costs across turns:

```elixir
{:ok, result} = Sycophant.Agent.run(agent)

result.stats.total_cost              #=> 0.0042
result.stats.total_input_tokens      #=> 1250
result.stats.total_output_tokens     #=> 340
result.stats.total_reasoning_tokens  #=> 500

# Per-turn breakdown
for turn <- Sycophant.Agent.Stats.turns(result.stats) do
  {turn.input_tokens, turn.output_tokens, turn.reasoning_tokens, turn.cost}
end
```

## Telemetry

Cost data is included in telemetry metadata on `[:sycophant, :request, :stop]`
events. The `pricing` struct is converted to plain maps for telemetry consumers.

```elixir
:telemetry.attach("cost-tracker", [:sycophant, :request, :stop],
  fn _event, _measurements, metadata, _config ->
    usage = metadata.usage
    Logger.info("Request cost: $#{usage[:total_cost]}")
  end,
  nil
)
```

See the [Telemetry guide](telemetry.md) for the full list of usage fields in
telemetry metadata.

## Serialization

`Pricing` and `Pricing.Component` structs implement the `Sycophant.Serializable`
protocol, so they round-trip through JSON alongside `Usage`:

```elixir
alias Sycophant.Serializable.Decoder

json = Decoder.encode(response.usage)
restored = Decoder.decode(json)
restored.pricing.currency  #=> "USD"
```

See the [Serialization guide](serialization.md) for details.
