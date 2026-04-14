# Custom Providers

Sycophant's provider system is modular and extensible. Adding a new LLM
provider requires implementing two behaviours and registering them.

## Overview

A provider consists of:

1. **Wire Protocol** -- encodes requests and decodes responses in the
   provider's API format
2. **Auth Strategy** -- handles authentication (headers, signing, query params)
3. **Registration** -- connects the provider to the pipeline at runtime

## Wire Protocol

Implement the `Sycophant.WireProtocol` behaviour. This is the core of a
provider integration.

### Required Callbacks

```elixir
defmodule MyApp.WireProtocol.CustomProvider do
  @behaviour Sycophant.WireProtocol

  alias Sycophant.{Request, Response, StreamChunk, ParamDefs}

  # Define accepted parameters by merging shared defs with provider-specific ones
  @param_schema Zoi.map(
    Map.merge(ParamDefs.shared(), %{
      custom_param: Zoi.string() |> Zoi.optional()
    })
  )

  @impl true
  def param_schema, do: @param_schema

  @impl true
  def request_path(_request), do: "/v1/chat/completions"

  @impl true
  def stream_transport, do: :sse  # or :event_stream for binary (like AWS)

  @impl true
  def encode_request(%Request{} = request) do
    payload = %{
      "model" => request.model,
      "messages" => Enum.map(request.messages, &encode_message/1)
    }

    payload = add_params(payload, request.params)
    payload = maybe_add_tools(payload, request.tools)
    payload = maybe_add_stream(payload, request.stream)

    {:ok, payload}
  end

  @impl true
  def decode_response(body) do
    {:ok,
     %Response{
       text: get_in(body, ["choices", Access.at(0), "message", "content"]),
       model: body["model"],
       usage: decode_usage(body["usage"]),
       finish_reason: decode_finish_reason(body),
       raw: body,
       context: %Sycophant.Context{messages: []}
     }}
  end

  @impl true
  def encode_tools(tools) do
    {:ok, Enum.map(tools, &encode_tool/1)}
  end

  @impl true
  def encode_response_schema(schema) do
    # schema is already a JSON Schema map (normalized by the pipeline)
    {:ok, schema}
  end

  @impl true
  def init_stream do
    %{text: "", tool_calls: [], usage: nil}
  end

  @impl true
  def decode_stream_chunk(state, %{data: "[DONE]"}) do
    {:done,
     %Response{
       text: state.text,
       usage: state.usage,
       raw: %{},
       context: %Sycophant.Context{messages: []}
     }}
  end

  def decode_stream_chunk(state, %{data: data}) do
    delta = get_in(data, ["choices", Access.at(0), "delta"])
    new_text = state.text <> (delta["content"] || "")

    chunks =
      if delta["content"] do
        [%StreamChunk{type: :text_delta, data: delta["content"]}]
      else
        []
      end

    {:ok, %{state | text: new_text}, chunks}
  end

  # Private helpers for encoding/decoding...
end
```

### Parameter Schema

The `param_schema/0` callback defines which LLM parameters the provider
accepts. Use `ParamDefs.shared()` as a base -- it includes common params like
`:temperature`, `:max_tokens`, `:top_p`, `:top_k`, `:stop`, `:reasoning`,
`:tool_choice`, and others.

Add provider-specific params by merging into the shared map:

```elixir
@param_schema Zoi.map(
  Map.merge(ParamDefs.shared(), %{
    logprobs: Zoi.boolean() |> Zoi.optional(),
    seed: Zoi.integer() |> Zoi.optional(),
    frequency_penalty: Zoi.number() |> Zoi.optional()
  })
)
```

The pipeline validates user-provided params against this schema. Params not
in the schema are dropped with a warning log.

### Stream Transport

Two transport modes are available:

- `:sse` -- Server-Sent Events (used by OpenAI, Anthropic, Google, OpenRouter)
- `:event_stream` -- Binary event-stream with frame decoding (used by AWS Bedrock)

Most providers use SSE. The `decode_stream_chunk/2` callback receives parsed
events and must return one of:

- `{:ok, new_state, chunks}` -- continue streaming with accumulated state
- `{:done, response}` -- stream complete, return final response
- `{:done, response, final_chunks}` -- stream complete with final chunks
- `{:error, error}` -- stream failed

## Auth Strategy

Implement `Sycophant.Auth` to handle authentication. The callback returns
Tesla middleware tuples.

### Header-based Auth

```elixir
defmodule MyApp.Auth.CustomProvider do
  @behaviour Sycophant.Auth

  @impl true
  def middlewares(%{api_key: key}) do
    [{Tesla.Middleware.Headers, [{"authorization", "Bearer #{key}"}]}]
  end
end
```

### Auth with Path Parameters

Some providers need dynamic URL segments (e.g., AWS region). Implement the
optional `path_params/1` callback:

```elixir
defmodule MyApp.Auth.RegionBased do
  @behaviour Sycophant.Auth

  @impl true
  def middlewares(credentials) do
    [{Tesla.Middleware.Headers, [{"x-api-key", credentials.api_key}]}]
  end

  @impl true
  def path_params(credentials) do
    [region: Map.get(credentials, :region, "us-east-1")]
  end
end
```

### Fallback

Providers without a registered auth strategy automatically use
`Sycophant.Auth.Bearer`, which sends the `api_key` credential as a
`Bearer` token in the `Authorization` header.

## Registration

Register your provider at application startup or any time before first use:

```elixir
# In your Application.start/2
def start(_type, _args) do
  Sycophant.Registry.register_protocol!(:chat, :custom_chat, MyApp.WireProtocol.CustomProvider)
  Sycophant.Registry.register_auth!(:custom, MyApp.Auth.CustomProvider)

  children = [...]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

The protocol name (second argument to `register_protocol!/3`) must match what
LLMDB returns in the model's `wire.protocol` metadata field (atomized).

The auth provider atom (first argument to `register_auth!/2`) must match the
provider atom from the model spec (e.g., `:custom` for `"custom:model-id"`).

### Built-in Registrations

Sycophant registers these automatically at startup:

**Chat protocols:**

| Name | Module |
|------|--------|
| `:openai_chat` | `OpenAICompletions` |
| `:openai_responses` | `OpenAIResponses` |
| `:anthropic_messages` | `AnthropicMessages` |
| `:google_gemini` | `GoogleGemini` |
| `:bedrock_converse` | `BedrockConverse` |

**Embedding protocols:**

| Name | Module |
|------|--------|
| `:openai_embed` | `EmbeddingWireProtocol.OpenAIEmbed` |
| `:bedrock_embed` | `EmbeddingWireProtocol.BedrockEmbed` |

**Auth strategies:**

| Provider | Module |
|----------|--------|
| `:amazon_bedrock` | `Auth.Bedrock` |
| `:anthropic` | `Auth.Anthropic` |
| `:azure` | `Auth.Azure` |
| `:google` | `Auth.Google` |

All other providers fall back to `Auth.Bearer`.

## Embedding Support

To add embedding support, implement `Sycophant.EmbeddingWireProtocol` and
register it:

```elixir
Sycophant.Registry.register_protocol!(:embedding, :custom_embed, MyApp.EmbeddingWireProtocol.Custom)
```

## Credentials Configuration

Once registered, credentials work through the standard three-layer fallback:

```elixir
# Per-request
Sycophant.generate_text(messages,
  model: "custom:my-model",
  credentials: %{api_key: "sk-..."}
)

# Application config
config :sycophant, :providers,
  custom: [api_key: System.get_env("CUSTOM_API_KEY")]

# Environment variables (discovered via LLMDB provider metadata)
```

## Local Providers (Ollama, vLLM, LM Studio)

Local inference servers that expose an OpenAI-compatible API can be used
without writing any custom code. They reuse the built-in `OpenAICompletions`
wire protocol and the `Bearer` auth fallback.

### Configuration

Register local providers as LLMDB custom providers. Set `auth: :none` (or
`auth: :optional` if the server accepts an API key) in the provider's
`extra` field, and `wire_protocol: "openai_chat"` in each model's `extra`:

```elixir
# config/runtime.exs
config :llm_db, :runtime,
  custom: %{
    ollama: [
      name: "Ollama",
      base_url: "http://localhost:11434/v1",
      extra: %{auth: :none},
      models: %{
        "llama3" => %{
          capabilities: %{chat: true},
          extra: %{wire: %{protocol: "openai_chat"}}
        },
        "deepseek-r1" => %{
          capabilities: %{chat: true, tools: %{enabled: true}},
          extra: %{wire: %{protocol: "openai_chat"}}
        }
      }
    ],
    vllm: [
      name: "vLLM",
      base_url: "http://localhost:8000/v1",
      extra: %{auth: :optional},
      models: %{
        "mistral-7b" => %{
          capabilities: %{chat: true},
          extra: %{wire: %{protocol: "openai_chat"}}
        }
      }
    ]
  }
```

For servers that require an API key (e.g., vLLM with `--api-key`), add
credentials through the standard config:

```elixir
config :sycophant, :providers,
  vllm: [api_key: System.get_env("VLLM_API_KEY")]
```

### Usage

Local providers work identically to cloud providers:

```elixir
messages = [Sycophant.Message.user("Hello")]

{:ok, response} = Sycophant.generate_text("ollama:llama3", messages)

{:ok, response} = Sycophant.generate_text("vllm:mistral-7b", messages,
  temperature: 0.7
)
```

Streaming, tool use, and structured output all work as long as the local
server supports them and the model's `capabilities` are declared correctly.

### Auth Modes

| `extra.auth` | Behavior |
|--------------|----------|
| `:none` | No credentials required. Pipeline proceeds with empty auth. |
| `:optional` | Credentials used when available, empty auth otherwise. |
| _(absent)_ | Standard behavior. `MissingCredentials` error if no credentials found. |

## Checklist

When adding a new provider:

1. Implement `Sycophant.WireProtocol` with all callbacks
2. Define `@param_schema` composing `ParamDefs.shared()` with extras
3. Implement `Sycophant.Auth` for authentication
4. Register via `Sycophant.Registry.register_protocol!/3` and `register_auth!/2` at startup
5. Add model metadata to LLMDB pointing to your wire protocol name
6. Add credentials configuration
7. Write recording tests (see [Recording Tests](recording-tests.md))
