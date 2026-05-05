defmodule Sycophant.Auth.GithubCopilot do
  @moduledoc """
  Authentication strategy for GitHub Copilot.

  Supports two credential modes:

    * **Managed** — caller supplies `:github_token` (OAuth token or PAT). The
      strategy exchanges it for a short-lived Copilot token via
      `Sycophant.Auth.GithubCopilot.TokenCache` and surfaces `:base_url` and
      `:copilot_token` back into the credential map.

    * **Escape hatch** — caller supplies an already-exchanged `:copilot_token`.
      No exchange happens; the base URL falls back to `:base_url` from
      credentials, then to a hardcoded constant.

  Editor identity headers (`copilot-integration-id`, `editor-version`,
  `editor-plugin-version`, `user-agent`) gate which models Copilot exposes.
  Defaults match the VS Code Copilot Chat extension. Override via the
  credential map.
  """

  @behaviour Sycophant.Auth

  alias Sycophant.Auth.GithubCopilot.TokenCache
  alias Sycophant.Error

  @default_github_host "github.com"
  @default_base_url "https://api.githubcopilot.com"
  @default_editor_version "vscode/1.95.0"
  @default_editor_plugin_version "copilot-chat/0.22.0"
  @default_integration_id "vscode-chat"
  @default_user_agent "GitHubCopilotChat/0.22.0"

  @impl true
  def prepare_credentials(%{copilot_token: token} = creds) when is_binary(token) do
    {:ok, Map.put_new(creds, :base_url, base_url_fallback(creds))}
  end

  def prepare_credentials(%{github_token: token} = creds) when is_binary(token) do
    host = Map.get(creds, :github_host, @default_github_host)

    case TokenCache.fetch(host, token) do
      {:ok, entry} ->
        {:ok,
         creds
         |> Map.put(:copilot_token, entry.copilot_token)
         |> Map.put(:base_url, pick_base_url(creds, entry))}

      {:error, _} = err ->
        err
    end
  end

  def prepare_credentials(_creds) do
    {:error,
     Error.Invalid.MissingCredentials.exception(
       provider: :github_copilot,
       errors: ["Either :github_token or :copilot_token is required"]
     )}
  end

  @impl true
  def middlewares(%{copilot_token: token} = creds) when is_binary(token) do
    [
      {Tesla.Middleware.Headers,
       [
         {"authorization", "Bearer #{token}"},
         {"copilot-integration-id", Map.get(creds, :integration_id, @default_integration_id)},
         {"editor-version", Map.get(creds, :editor_version, @default_editor_version)},
         {"editor-plugin-version",
          Map.get(creds, :editor_plugin_version, @default_editor_plugin_version)},
         {"user-agent", Map.get(creds, :user_agent, @default_user_agent)}
       ]}
    ]
  end

  def middlewares(_), do: []

  defp pick_base_url(%{base_url: url}, _entry) when is_binary(url), do: url
  defp pick_base_url(_creds, %{endpoints: %{api: url}}) when is_binary(url), do: url
  defp pick_base_url(_creds, _entry), do: @default_base_url

  defp base_url_fallback(%{base_url: url}) when is_binary(url), do: url
  defp base_url_fallback(_), do: @default_base_url
end
