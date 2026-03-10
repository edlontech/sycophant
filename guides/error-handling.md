# Error Handling

Sycophant uses [Splode](https://hexdocs.pm/splode) for structured error
handling. All errors implement `Splode.Error` and are organized into three
classes.

## Error Classes

### Invalid (caller errors)

Errors you can fix before sending the request:

| Error | When |
|-------|------|
| `MissingModel` | No `:model` option provided |
| `MissingCredentials` | No credentials found for the provider |
| `InvalidParams` | Parameters fail Zoi schema validation |
| `InvalidSchema` | Response schema is malformed |
| `InvalidResponse` | Response fails schema validation |
| `InvalidSerialization` | Deserialization encounters unknown type |
| `InvalidEmbeddingInput` | Embedding input is malformed |
| `InvalidRegistration` | Module registration error |

### Provider (remote API errors)

Errors from the LLM provider's API:

| Error | When |
|-------|------|
| `RateLimited` | API rate limit exceeded (HTTP 429) |
| `ServerError` | Provider returned 5xx |
| `BadRequest` | Provider rejected the request (HTTP 400) |
| `AuthenticationFailed` | Invalid credentials (HTTP 401/403) |
| `ModelNotFound` | Model does not exist at the provider |
| `ContentFiltered` | Content was blocked by safety filters |
| `ResponseInvalid` | Provider returned unparseable response |

### Unknown

Catch-all for errors that don't fit the above categories.

## Pattern Matching

Match on specific error modules for targeted handling:

```elixir
case Sycophant.generate_text(messages, model: "openai:gpt-4o-mini") do
  {:ok, response} ->
    response.text

  {:error, %Sycophant.Error.Provider.RateLimited{}} ->
    Process.sleep(1000)
    retry()

  {:error, %Sycophant.Error.Provider.ContentFiltered{}} ->
    "Content was blocked by safety filters"

  {:error, %Sycophant.Error.Invalid.MissingCredentials{}} ->
    "Please configure your API key"

  {:error, error} ->
    Logger.error("LLM request failed: #{Splode.Error.message(error)}")
    "Something went wrong"
end
```

## Matching by Class

Match on the error class to handle categories:

```elixir
case Sycophant.generate_text(messages, model: "openai:gpt-4o-mini") do
  {:ok, response} ->
    {:ok, response}

  {:error, %{class: :invalid}} ->
    # Caller mistake -- fix the request and retry
    {:error, :bad_request}

  {:error, %{class: :provider}} ->
    # Remote failure -- log and maybe retry
    {:error, :provider_error}

  {:error, _} ->
    {:error, :unknown}
end
```

## Error Messages

Use `Splode.Error.message/1` to get a human-readable description:

```elixir
{:error, error} = Sycophant.generate_text(messages, model: "bad:model")
Splode.Error.message(error)
#=> "Model not found: bad:model"
```

## Telemetry Integration

Failed requests emit `[:sycophant, :request, :error]` telemetry events with
the error and its class in the metadata. See the [Telemetry](telemetry.md)
guide for details.
