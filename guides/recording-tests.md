# Recording Tests

Sycophant uses a fixture-based recording system to test against real LLM
provider APIs without making live calls on every test run. Fixtures are
recorded once and replayed automatically.

## How It Works

1. Run tests with `RECORD=true` to make real API calls and save responses
2. Fixtures are stored as JSON files in `priv/fixtures/recordings/`
3. Subsequent runs replay fixtures without network access
4. Credentials are automatically redacted from saved fixtures

## Running Recording Tests

```bash
# Replay existing fixtures (default)
mix test.recording

# Record missing fixtures (makes live API calls)
RECORD=true mix test.recording

# Force re-record all fixtures (overwrites existing)
RECORD=force mix test.recording

# Filter by provider
RECORD=true RECORD_MODELS=anthropic mix test.recording

# Filter by specific model (prefix matching)
RECORD=true RECORD_MODELS=anthropic:claude-haiku mix test.recording

# Multiple providers
RECORD=true RECORD_MODELS=openai,google mix test.recording
```

## Test Configuration

Models available for recording tests are defined in `config/test.exs`:

```elixir
config :sycophant, :test_models, [
  %{model: "openai:gpt-4o-mini", structured_output: true},
  %{model: "anthropic:claude-haiku-4-5-20251001", structured_output: true},
  %{model: "google:gemini-2.5-flash", structured_output: true},
  %{model: "amazon_bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0", structured_output: true}
]

config :sycophant, :test_embedding_models, [
  %{model: "amazon_bedrock:cohere.embed-v4"}
]
```

Each entry can include capability flags (like `structured_output: true`) used
to filter which models run specific tests.

## Writing Recording Tests

### Parameterized Tests (Recommended)

Run the same test against every configured model:

```elixir
defmodule Sycophant.Recording.MyFeatureTest do
  @models Sycophant.RecordingCase.test_models()
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "generates text", %{model: model} do
    messages = [Message.user("Say 'hello' and nothing else.")]

    assert {:ok, response} =
             Sycophant.generate_text(model, messages, recording_opts([]))

    assert is_binary(response.text)
    assert String.length(response.text) > 0
  end
end
```

This creates one fixture per model:
- `priv/fixtures/recordings/openai/gpt-4o-mini/generates_text.json`
- `priv/fixtures/recordings/anthropic/claude-haiku-4-5-20251001/generates_text.json`
- etc.

### Capability Filtering

Only run a test against models that support a specific feature:

```elixir
@models Sycophant.RecordingCase.test_models(require: :structured_output)
use Sycophant.RecordingCase, async: true, parameterize: @models

@tag recording_prefix: true
test "generates structured output", %{model: model} do
  schema = Zoi.object(%{name: Zoi.string()})
  messages = [Message.user("Extract: Alice")]

  assert {:ok, response} =
           Sycophant.generate_object(model, messages, schema, recording_opts([]))

  assert response.object.name == "Alice"
end
```

### Explicit Recording Names

For tests that need custom fixture paths (e.g., Azure deployments):

```elixir
@tag recording: "azure/gpt-5-mini/generates_text"
test "generates text with Azure" do
  messages = [Message.user("Say hello")]

  assert {:ok, response} =
           Sycophant.generate_text("azure:gpt-5-mini", messages,
             recording_opts(
               credentials: %{
                 api_key: System.get_env("AZURE_API_KEY"),
                 base_url: System.get_env("AZURE_BASE_URL"),
                 deployment_name: "gpt-5-mini"
               }
             )
           )

  assert is_binary(response.text)
end
```

### Streaming Tests

Streaming works transparently. The middleware records the full SSE event
stream and replays it:

```elixir
@tag recording_prefix: true
test "streams text", %{model: model} do
  test_pid = self()

  callback = fn chunk ->
    send(test_pid, {:chunk, chunk})
  end

  messages = [Message.user("Say 'hello' and nothing else.")]

  assert {:ok, response} =
           Sycophant.generate_text(model, messages,
             recording_opts(stream: callback)
           )

  assert is_binary(response.text)
  assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta}}
end
```

### Multi-request Tests

When a test makes multiple API calls, fixtures are automatically sequenced:

```elixir
@tag recording_prefix: true
test "continues a multi-turn conversation", %{model: model} do
  alias Sycophant.Context

  messages = [Message.user("My name is Sycophant. Remember it.")]

  {:ok, resp1} = Sycophant.generate_text(model, messages, recording_opts([]))

  ctx = resp1.context |> Context.add(Message.user("What is my name?"))
  {:ok, resp2} = Sycophant.generate_text(model, ctx, recording_opts([]))

  history = Sycophant.Response.messages(resp2)
  assert length(history) == 4
end
```

This creates two fixtures:
- `continues_a_multi_turn_conversation.json` (first request)
- `continues_a_multi_turn_conversation_2.json` (second request)

## The `recording_opts/1` Helper

Always wrap your options with `recording_opts/1`. It handles credential
injection automatically:

- **Recording mode** (`RECORD=true`): passes your options through so real
  credentials are used
- **Replay mode** (default): injects dummy credentials since the fixture
  already contains the response

```elixir
# Always use recording_opts to wrap your options
Sycophant.generate_text(model, messages, recording_opts([]))
Sycophant.generate_text(model, messages, recording_opts(temperature: 0.5))
```

## Fixture Format

Each fixture is a JSON file with three sections:

```json
{
  "metadata": {
    "recorded_at": "2026-03-05T18:03:45Z",
    "sycophant_version": "0.1.0",
    "model": "claude-haiku-4-5-20251001",
    "provider": "api.anthropic.com",
    "streaming": true
  },
  "request": {
    "method": "post",
    "url": "https://api.anthropic.com/v1/messages",
    "headers": [["x-api-key", "[REDACTED]"]],
    "body": { "model": "...", "messages": [...] }
  },
  "response": {
    "status": 200,
    "headers": [...],
    "body": { ... }
  }
}
```

Sensitive headers are automatically redacted: `authorization`, `x-api-key`,
`api-key`, `x-goog-api-key`, `x-amz-security-token`, and others.

## Fixture Naming

When using `@tag recording_prefix: true`, fixture names are derived from the
test name:

| Test Name | Fixture File |
|-----------|-------------|
| `"generates text"` | `generates_text.json` |
| `"calls a tool and returns tool_calls"` | `calls_a_tool_and_returns_tool_calls.json` |

## Directory Structure

```
priv/fixtures/recordings/
  anthropic/
    claude-haiku-4-5-20251001/
      generates_text.json
      streams_text.json
      continues_a_multi_turn_conversation.json
      continues_a_multi_turn_conversation_2.json
  openai/
    gpt-4o-mini/
      generates_text.json
  google/
    gemini-2.5-flash/
      generates_text.json
  amazon_bedrock/
    us.anthropic.claude-sonnet-4-5-20250929-v1/
      0/
        generates_text.json
```

## Best Practices

- Use parameterized tests for cross-provider coverage
- Use `recording_prefix: true` for automatic fixture naming
- Use explicit `@tag recording:` only when you need custom paths
- Keep test prompts deterministic ("Say 'hello' and nothing else")
- Commit fixtures to version control -- they are safe (credentials stripped)
- Re-record fixtures when changing request encoding or adding providers
