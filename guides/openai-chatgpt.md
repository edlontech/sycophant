# OpenAI ChatGPT Plan

Sign in with ChatGPT lets open-source, locally hosted applications use a user's
ChatGPT plan through `POST https://api.openai.com/v1/responses`. This is not an
API key or a general-purpose hosted-service billing route. Account eligibility,
plan quotas, and the preview's request restrictions apply.

`Sycophant.OAuth.OpenAI` provides OAuth 2.0 authorization code flow with PKCE
(`S256`) and OpenID Connect validation. Your application owns the browser,
loopback callback server, secure storage, and refresh scheduling. Sycophant
starts no OAuth process and never refreshes automatically.

## Installation identity and redirect URI

Generate and persist a stable opaque installation ID before first login, for
example `urn:uuid:12345678-1234-1234-1234-123456789abc`. `host_id` must match
`~r/^urn:uuid:[0-9a-f-]{36}$/i`; it becomes `ext_agent_host_id` on authorization.
Reuse it for that installation rather than generating one on every login.

Your application must own a redirect such as
`http://127.0.0.1:1455/auth/callback`. Use `127.0.0.1`, never `localhost`.
Keep the scheme, host, and path fixed for your app; only the port may vary.
Start the callback listener before opening the browser. Exchange sends the
exact redirect URI captured in the pending session.

## First login

```elixir
alias Sycophant.OAuth.OpenAI

{:ok, url, session} =
  OpenAI.authorize_url(
    host_id: installation.host_id,
    agent_name: "Yach",
    redirect_uri: "http://127.0.0.1:1455/auth/callback"
  )
```

Hold `session` securely for this pending login and open `url` in the user's
browser using your platform's browser launcher. Do not log the URL or tokens.
The first request uses `client_id=dynamic_agent_client`, `agent_name_hint=Yach`,
`resource=https://api.openai.com/v1`, and all six scopes:
`openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`.
It sends no ID-token or login hint.

When your listener receives the callback, pass its string-keyed query params
and the matching session to exchange:

```elixir
{:ok, credential} = OpenAI.exchange(session, callback_params)
```

Handle errors instead of pattern matching in production. Exchange checks state,
code, client ID, and the ID token's signature, issuer, audience, expiry, and
nonce. First registration must return an issued `oaiapp_...` client ID. Persist
the complete credential securely, including that ID, all tokens, scopes, and
expiry. Discard the pending session after use. Never log or emit credentials
in telemetry. Custom `Inspect` redacts tokens, but serialized credentials still
contain secrets and need encrypted storage and access controls.

## Check plan consent

```elixir
if OpenAI.plan_usage_enabled?(credential) do
  :ready
else
  :offer_reauthorization_or_api_key
end
```

Only the granted `chatgpt.tokens.use.direct` scope enables plan usage. Without
it, the sign-in is still valid. Keep the credential and offer re-authorization
or a separately configured API key, rather than treating sign-in as failed.

## Re-login

Use the persisted installation ID, issued client ID, and ID token:

```elixir
{:ok, url, session} =
  OpenAI.authorize_url(
    host_id: installation.host_id,
    redirect_uri: "http://127.0.0.1:1455/auth/callback",
    client_id: credential.client_id,
    id_token_hint: credential.id_token,
    login_hint: credential.email
  )
```

Omit `login_hint` if no email is available. Re-login requests the full scope set
without `agent_name_hint`. Open the URL and exchange the callback as before.
A callback with a different client ID is rejected.

## Refresh and logout

`Sycophant.OAuth.Credential.expired?/1` checks whether expiry is within 180
seconds by default. Refresh before expiry:

```elixir
{:ok, refreshed} = OpenAI.refresh(credential)
```

Persist the returned credential atomically before making it available to other
callers. Refresh tokens rotate and the old token can become invalid. Assign
exactly one refresh owner per credential, including across app processes or
nodes; serialize refreshes. Sycophant does not coordinate refresh ownership.
Keep the existing credential on transient failures. See the error table below
for the codes that require re-login.

For logout, call `OpenAI.revoke(credential)` and remove local credentials
according to your app's logout policy. Revocation is best effort. It posts the
refresh token, `token_type_hint=refresh_token`, and issued client ID to the static
URL `https://auth.openai.com/api/accounts/oauth/revoke`. Remote revocation may
not be available for transferred sessions; do not promise remote invalidation.

## Account-visible models

```elixir
{:ok, models} = OpenAI.list_models(credential)
# [%{slug: "...", display_name: "..."}]
```

You can also pass the access-token string directly. This calls
`GET https://api.openai.com/v1/models` with Bearer authentication and returns
only entries whose `visibility` is `list`, preserving their order. It does not
register models in LLMDB or refresh an expired credential.

## Inference and restrictions

Choose a Responses-compatible model available to the account:

```elixir
{:ok, response} =
  Sycophant.generate_text("openai:#{model_slug}", [
    %Sycophant.Message{role: :user, content: "Hello."}
  ], credentials: %{access_token: credential.access_token})
```

Do not combine `access_token` and `api_key` in one credential map. Per-request
credentials replace app configuration wholesale; they do not merge with it.

The subscription route forces `store: false` and `stream: true`. Sync callers
still receive a normal `Sycophant.Response`; `Context.stream` stays `nil`.
Sycophant drops `temperature`, `top_p`, `max_tokens`, `max_tool_calls`, `metadata`,
`cache_retention`, `safety_identifier`, `top_logprobs`, `truncation`, and
`previous_response_id`, with debug logging of parameter names. On the wire,
`max_tokens` maps to `max_output_tokens` and `cache_retention` to
`prompt_cache_retention`; neither is sent on this route.

The preview also forbids `background`, `conversation`, `moderation`,
`multi_agent`, `prompt`, and `user`. Do not pass these provider-level fields.
System messages become top-level `instructions`, never
`{type: "message", role: "system"}` items. Function tools use the flat
`type: "function"` contract. Reasoning models request
`include: ["reasoning.encrypted_content"]`. Continue with the returned response
or context to replay encrypted reasoning and history without
`previous_response_id`. Tokens must never appear in logs, telemetry metadata,
or `Response.raw`.

### Subscription-only model slugs

A slug returned by `list_models/1` may be absent from LLMDB. In that case model
resolution returns `MissingModel`. Wait for a catalog update or register the
exact slug through runtime custom configuration, using its actual capabilities:

```elixir
config :llm_db, :runtime,
  custom: %{
    openai: [
      models: %{
        "your-subscription-model-slug" => %{
          capabilities: %{chat: true},
          extra: %{wire: %{protocol: "openai_responses"}}
        }
      }
    ]
  }
```

For a reasoning model, also set `capabilities.reasoning.enabled` to `true`.
Configuration does not grant access to models unavailable to the account.

## Error handling

`SubscriptionError` preserves `code`, `status`, `param`, and `request_id` for
`subscription_sharing_*` and `chatpass_v2_*` failures, including
`response.failed` mid-stream. Branch on codes, not message text.

| Situation or code | Application action |
|-------------------|--------------------|
| `OAuthFailed`, `access_denied` | Cancel the pending login; no token request was made. |
| State mismatch, missing code or issued client ID, mismatched re-login client ID | Reject the callback; no token exchange. Start a new login if needed. |
| Invalid ID token signature, issuer, audience, expiry, or nonce | Reject the login; no credential is returned. |
| Missing `chatgpt.tokens.use.direct` scope | Keep the valid sign-in; offer re-authorization or API-key billing. |
| Refresh `OAuthFailed` with `invalid_grant` or `refresh_token_*` | Re-login with the issued client ID. |
| Other exchange or refresh failures, including network `OAuthFailed` with `code: nil` | Keep any stored credential. Retry transient failures with backoff; do not force re-login just because a request failed. |
| `subscription_sharing_invalid_user` | Require re-login. |
| `subscription_sharing_usage_limit_exceeded` | Pause plan requests until quota is available. |
| `subscription_sharing_user_not_eligible` | Explain account or plan eligibility; offer another billing path. |
| `subscription_sharing_usage_unavailable` | Back off and retry later. |
| Other `subscription_sharing_*` or `chatpass_v2_*` codes | Preserve the exact code and request ID for diagnosis; do not assume every failure needs re-login. |
| Inference or model-list 401, `AuthenticationFailed` | Decide whether to refresh or re-login. Sycophant never refreshes for you. |
| Other HTTP errors without subscription codes | Handle standard errors: 429 `RateLimited`, 403 `BadRequest`, 5xx `ServerError`. |
| Stream ends without `response.completed` | Handle `ResponseInvalid`; do not treat partial output as a completed response. |
| Both `access_token` and `api_key` | Fix the credential map; `InvalidParams` rejects it. |
| Unknown model slug | Register it in LLMDB or wait for a catalog update. |
| Revocation failure | Treat as best effort; apply local logout policy without promising remote revocation. |
