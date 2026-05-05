# GitHub Copilot

Sycophant's GitHub Copilot adapter exposes Copilot's chat models through the
same API as every other provider. **Caveat first: Copilot's chat endpoint is
undocumented and reverse-engineered.** GitHub publishes no official API for
this; the implementation could break without warning. All requests count
against your Copilot subscription quota and may violate GitHub's terms of
service depending on your use case. Use at your own risk.

## Quick start

Set a GitHub OAuth App token from the VS Code Copilot device flow in your
environment:

    export GITHUB_TOKEN=gho_youroauthtoken

Then call any Copilot model:

    Sycophant.generate_text("github_copilot:gpt-4o", [
      %Sycophant.Message{role: :user, content: "Hello, Copilot."}
    ])

## Getting a token

The `copilot_internal/v2/token` endpoint accepts only tokens minted by a
specific allowlist of OAuth Apps. **Personal access tokens (classic or
fine-grained, with any scope or permission) are rejected with HTTP 403
"Resource not accessible by personal access token"** -- this is a hard
constraint of the endpoint, not a token-permission issue.

The reliable way to get an accepted token is the OAuth device flow against
the public VS Code Copilot client ID `Iv1.b507a08c87ecfe98`. This repo ships
a helper:

    mix run scripts/copilot_login.exs

It prints a URL plus a short user code; open the URL in a browser, paste the
code, approve, and the script polls until GitHub releases the access token.
The output ends with the `export` (or `set -lx`) line you need.

Tokens issued by the standard `gh` CLI may or may not work depending on
which OAuth App or GitHub App `gh` is registered as on your install -- newer
`gh` releases use a GitHub App (`ghu_...` prefix) that is **not** on the
Copilot allowlist. Use the device-flow script instead.

## How it works

GitHub Copilot's chat API requires a short-lived (~25 minute) JWT obtained by
exchanging your GitHub token at `/copilot_internal/v2/token`. Sycophant handles
the exchange and caches the resulting Copilot token in a supervised
`GenServer`, refreshing it ~30 seconds before expiry. The exchange response
also returns the correct `endpoints.api` host for your Copilot plan
(Individual, Business, or Enterprise) -- Sycophant uses that as the chat base
URL automatically.

```
Your GitHub token
       |
       v
GET /copilot_internal/v2/token  -->  {token, expires_at, endpoints.api}
       |
       v
TokenCache (refresh ~30s before expiry)
       |
       v
Bearer Copilot token + chat base URL
       |
       v
POST {endpoints.api}/chat/completions
```

## Configuration

Three layers, checked in order. **Note that layers do not merge -- the first
non-empty layer wins.**

### Layer 1: per-request

    Sycophant.generate_text("github_copilot:gpt-4o", messages,
      credentials: %{
        github_token: "ghp_x",
        github_host: "ghe.example.com",          # for GHE; default "github.com"
        editor_version: "vscode/1.95.0",
        editor_plugin_version: "copilot-chat/0.22.0",
        integration_id: "vscode-chat"
      }
    )

If you pass `credentials:` per-request, you must include every field you need.
Sycophant does not merge per-request credentials with app config or env.

### Layer 2: app config

    config :sycophant, :providers,
      github_copilot: [
        github_token: System.get_env("GITHUB_TOKEN"),
        github_host: "github.com"
      ]

### Layer 3: environment

    GITHUB_TOKEN=ghp_yourpat

## GitHub Enterprise Server

Set `:github_host` (per-request or in app config) to your GHE host:

    config :sycophant, :providers,
      github_copilot: [
        github_token: System.get_env("GITHUB_TOKEN"),
        github_host: "github.example.com"
      ]

The token-exchange URL becomes
`https://github.example.com/api/v3/copilot_internal/v2/token`.

## Escape hatch -- supplying a pre-exchanged Copilot token

If you already manage the GitHub->Copilot exchange yourself (e.g. inside a CLI
that performs the OAuth device flow), pass a `:copilot_token` directly. The
exchange is skipped:

    Sycophant.generate_text("github_copilot:gpt-4o", messages,
      credentials: %{copilot_token: "tid=..."}
    )

In this mode, the chat base URL falls back to `:base_url` from credentials, or
to `https://api.githubcopilot.com` if no override is given.

## Editor identity headers

GitHub Copilot's catalog and rate behaviour are gated by editor identity
headers. Sycophant sends VS-Code-Copilot-Chat-extension-equivalent values by
default. Override per credentials:

    credentials: %{
      github_token: "ghp_x",
      editor_version: "myeditor/1.0",
      editor_plugin_version: "myeditor-llm/1.0",
      integration_id: "my-integration",
      user_agent: "myeditor-llm/1.0"
    }

## Caveats

- **Reverse-engineered, undocumented.** Endpoint URLs and the response shape
  could change without notice.
- **Tokens count.** Every chat request consumes from your Copilot quota.
- **No structured outputs.** Copilot models do not support `response_schema`.
  Sycophant rejects requests that include one with `Error.Invalid.InvalidParams`.
- **No `temperature` for some models.** GPT-5.1+ models reject the
  `temperature` parameter; Sycophant drops it with a warning when LLMDB
  reports `extra.temperature == false`.
- **No embeddings.** Copilot's embeddings surface is not supported.
- **Terms of service.** Programmatic use of Copilot may violate GitHub's terms
  for some users. Check before deploying.
