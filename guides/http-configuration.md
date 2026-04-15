# HTTP Configuration

Sycophant uses Tesla as its HTTP layer. You can configure the adapter,
add middleware, and customize transport behaviour through application config.

## Tesla Adapter

By default, Sycophant uses whatever Tesla adapter is configured globally
(typically Hackney). To use a different adapter:

```elixir
# config/config.exs or config/runtime.exs
config :sycophant, :tesla,
  adapter: Tesla.Adapter.Mint
```

Adapters can also receive options as a tuple:

```elixir
config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Mint, [protocols: [:http2]]}
```

### Available Adapters

Any Tesla adapter works. Common choices:

| Adapter | Package | Notes |
|---------|---------|-------|
| `Tesla.Adapter.Hackney` | `:hackney` | Default in most Tesla setups |
| `Tesla.Adapter.Mint` | `:mint` | Lightweight, HTTP/2 support |
| `Tesla.Adapter.Finch` | `:finch` | Connection pooling, HTTP/2 |
| `Tesla.Adapter.Quiver` | `:quiver` | High-performance, HTTP/2 pools |

For Finch, you need to start a pool in your supervision tree:

```elixir
# In your Application.start/2
children = [
  {Finch, name: MyApp.Finch}
]

# config/runtime.exs
config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Finch, name: MyApp.Finch}
```

## Custom Middleware

Add Tesla middleware that runs on every Sycophant request:

```elixir
config :sycophant, :tesla,
  middlewares: [Tesla.Middleware.Logger]
```

Multiple middleware are applied in order:

```elixir
config :sycophant, :tesla,
  adapter: Tesla.Adapter.Mint,
  middlewares: [
    Tesla.Middleware.Logger,
    {Tesla.Middleware.Retry, delay: 1000, max_retries: 3},
    {Tesla.Middleware.Timeout, timeout: 30_000}
  ]
```

Your custom middleware is appended after Sycophant's built-in middleware
(BaseUrl, PathParams, JSON/Headers) and auth middleware.

## How the Client Is Built

For each request, Sycophant constructs a fresh Tesla client with this
middleware stack:

**Synchronous requests:**

1. `Tesla.Middleware.BaseUrl` -- sets the provider's base URL
2. `Tesla.Middleware.PathParams` -- interpolates URL path parameters
3. `Tesla.Middleware.JSON` -- encodes/decodes JSON bodies
4. Auth middleware -- provider-specific (Bearer, x-api-key, SigV4, etc.)
5. Your custom middleware from config

**SSE streaming requests:**

1. `Tesla.Middleware.BaseUrl`
2. `Tesla.Middleware.PathParams`
3. `Tesla.Middleware.Headers` -- sets `Content-Type: application/json`
4. `Tesla.Middleware.SSE` -- parses Server-Sent Events
5. Auth middleware
6. Your custom middleware

The adapter is configured with `response: :stream` for streaming requests
automatically.

## Environment-specific Configuration

Use different adapters per environment:

```elixir
# config/dev.exs
config :sycophant, :tesla,
  middlewares: [Tesla.Middleware.Logger]

# config/test.exs
config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Quiver, name: Sycophant.Quiver},
  middlewares: [{Sycophant.Tesla.RecorderMiddleware, []}]

# config/prod.exs
config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Finch, name: MyApp.Finch},
  middlewares: [
    {Tesla.Middleware.Timeout, timeout: 60_000}
  ]
```

## Error Mapping

Sycophant maps HTTP status codes to typed errors regardless of adapter:

| Status | Error |
|--------|-------|
| 401 | `AuthenticationFailed` |
| 404 | `ModelNotFound` |
| 429 | `RateLimited` (parses `Retry-After` header) |
| 400-499 | `BadRequest` |
| 500+ | `ServerError` |

Timeouts surface as `Timeout` errors. Other connection failures surface as `Unknown` errors.

## Logging Requests

The simplest way to debug HTTP traffic is with Tesla's built-in logger:

```elixir
config :sycophant, :tesla,
  middlewares: [Tesla.Middleware.Logger]
```

For more control, use the `filter_headers` option to avoid logging API keys:

```elixir
config :sycophant, :tesla,
  middlewares: [
    {Tesla.Middleware.Logger,
     filter_headers: ["authorization", "x-api-key", "api-key", "x-goog-api-key"]}
  ]
```
