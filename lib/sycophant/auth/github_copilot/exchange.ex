defmodule Sycophant.Auth.GithubCopilot.Exchange do
  @moduledoc """
  Performs the GitHub->Copilot token exchange.

  This is a reverse-engineered, undocumented endpoint. See the design doc
  at `docs/superpowers/specs/2026-05-05-github-copilot-provider-design.md`
  for caveats.
  """

  alias Sycophant.Error

  @default_user_agent "GitHubCopilotChat/0.22.0"
  @default_editor_version "vscode/1.95.0"
  @default_editor_plugin_version "copilot-chat/0.22.0"

  @doc """
  Exchanges a GitHub OAuth token / PAT for a short-lived Copilot token.

  `github_host` defaults to `"github.com"`. For GitHub Enterprise Server,
  pass the Enterprise host (e.g. `"github.example.com"`); the URL is then
  constructed as `https://{host}/api/v3/copilot_internal/v2/token`.

  Returns `{:ok, entry}` on success, where `entry` is a map with
  `:copilot_token`, `:expires_at` (DateTime), `:endpoints`, and
  `:fetched_at` keys. Returns `{:error, splode_error}` otherwise.
  """
  @spec exchange(String.t(), String.t()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def exchange(github_host, github_token) do
    url = build_url(github_host)
    {:ok, tesla_config} = Sycophant.Config.tesla()

    middlewares = [
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"authorization", "token #{github_token}"},
         {"accept", "application/json"},
         {"user-agent", @default_user_agent},
         {"editor-version", @default_editor_version},
         {"editor-plugin-version", @default_editor_plugin_version}
       ]}
    ]

    client = Tesla.client(middlewares, tesla_config.adapter)

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        decode_body(body)

      {:ok, %Tesla.Env{status: 401}} ->
        {:error,
         Error.Invalid.MissingCredentials.exception(
           provider: :github_copilot,
           errors: ["GitHub token rejected by Copilot token endpoint"]
         )}

      {:ok, %Tesla.Env{status: 403}} ->
        {:error,
         Error.Invalid.MissingCredentials.exception(
           provider: :github_copilot,
           errors: ["GitHub token forbidden from Copilot token endpoint"]
         )}

      {:ok, %Tesla.Env{status: 404}} ->
        {:error,
         Error.Invalid.MissingCredentials.exception(
           provider: :github_copilot,
           errors: ["GitHub account has no Copilot subscription"]
         )}

      {:ok, %Tesla.Env{status: 429}} ->
        {:error, Error.Provider.RateLimited.exception([])}

      {:ok, %Tesla.Env{status: status, body: body}} when status >= 500 ->
        {:error, Error.Provider.ServerError.exception(body: body)}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error,
         Error.Provider.ServerError.exception(
           body: "Unexpected status #{status}: #{inspect(body)}"
         )}

      {:error, reason} ->
        {:error, Error.Provider.ServerError.exception(body: inspect(reason))}
    end
  end

  defp build_url("github.com"), do: "https://api.github.com/copilot_internal/v2/token"
  defp build_url(host), do: "https://#{host}/api/v3/copilot_internal/v2/token"

  defp decode_body(%{"token" => token, "expires_at" => expires_at} = body) do
    {:ok,
     %{
       copilot_token: token,
       expires_at: DateTime.from_unix!(expires_at),
       endpoints: decode_endpoints(body["endpoints"]),
       fetched_at: DateTime.utc_now()
     }}
  end

  defp decode_body(body) do
    {:error,
     Error.Provider.ServerError.exception(
       body: "Malformed Copilot token response: #{inspect(body)}"
     )}
  end

  defp decode_endpoints(%{"api" => api} = endpoints) do
    %{
      api: api,
      proxy: endpoints["proxy"],
      telemetry: endpoints["telemetry"]
    }
  end

  defp decode_endpoints(_), do: %{api: nil, proxy: nil, telemetry: nil}
end
