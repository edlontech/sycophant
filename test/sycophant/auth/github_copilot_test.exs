defmodule Sycophant.Auth.GithubCopilotTest do
  use ExUnit.Case, async: false

  use Mimic

  alias Sycophant.Auth.GithubCopilot
  alias Sycophant.Auth.GithubCopilot.TokenCache
  alias Sycophant.Error

  setup do
    Mimic.copy(TokenCache)
    :ok
  end

  describe "prepare_credentials/1 — escape hatch" do
    test ":copilot_token bypasses exchange" do
      TokenCache |> reject(:fetch, 2)

      assert {:ok, prepared} =
               GithubCopilot.prepare_credentials(%{copilot_token: "tid=already"})

      assert prepared.copilot_token == "tid=already"
      assert prepared.base_url == "https://api.githubcopilot.com"
    end

    test ":base_url override wins over fallback in escape hatch" do
      TokenCache |> reject(:fetch, 2)

      assert {:ok, prepared} =
               GithubCopilot.prepare_credentials(%{
                 copilot_token: "tid=x",
                 base_url: "https://custom.example.com"
               })

      assert prepared.base_url == "https://custom.example.com"
    end
  end

  describe "prepare_credentials/1 — exchange flow" do
    test "calls TokenCache.fetch with default host and populates :copilot_token + :base_url" do
      TokenCache
      |> expect(:fetch, fn "github.com", "ghp_x" ->
        {:ok,
         %TokenCache.Entry{
           copilot_token: "tid=fresh",
           expires_at: DateTime.add(DateTime.utc_now(), 1500, :second),
           endpoints: %{api: "https://api.individual.githubcopilot.com"},
           fetched_at: DateTime.utc_now()
         }}
      end)

      assert {:ok, prepared} = GithubCopilot.prepare_credentials(%{github_token: "ghp_x"})
      assert prepared.copilot_token == "tid=fresh"
      assert prepared.base_url == "https://api.individual.githubcopilot.com"
    end

    test "uses GHE host when :github_host set" do
      TokenCache
      |> expect(:fetch, fn "ghe.example.com", "ghp_x" ->
        {:ok,
         %TokenCache.Entry{
           copilot_token: "tid=ghe",
           expires_at: DateTime.add(DateTime.utc_now(), 1500, :second),
           endpoints: %{api: "https://copilot.ghe.example.com"},
           fetched_at: DateTime.utc_now()
         }}
      end)

      assert {:ok, _} =
               GithubCopilot.prepare_credentials(%{
                 github_token: "ghp_x",
                 github_host: "ghe.example.com"
               })
    end

    test ":base_url credential override wins over endpoints.api" do
      TokenCache
      |> expect(:fetch, fn _, _ ->
        {:ok,
         %TokenCache.Entry{
           copilot_token: "tid=x",
           expires_at: DateTime.add(DateTime.utc_now(), 1500, :second),
           endpoints: %{api: "https://from-endpoint"},
           fetched_at: DateTime.utc_now()
         }}
      end)

      assert {:ok, prepared} =
               GithubCopilot.prepare_credentials(%{
                 github_token: "ghp_x",
                 base_url: "https://override"
               })

      assert prepared.base_url == "https://override"
    end

    test "propagates exchange errors" do
      TokenCache
      |> expect(:fetch, fn _, _ ->
        {:error, Error.Invalid.MissingCredentials.exception(provider: :github_copilot)}
      end)

      assert {:error, %Error.Invalid.MissingCredentials{}} =
               GithubCopilot.prepare_credentials(%{github_token: "bad"})
    end
  end

  describe "prepare_credentials/1 — missing credentials" do
    test "returns MissingCredentials when neither token present" do
      assert {:error, %Error.Invalid.MissingCredentials{}} =
               GithubCopilot.prepare_credentials(%{})
    end
  end

  describe "middlewares/1" do
    test "default editor identity headers + bearer" do
      [{Tesla.Middleware.Headers, headers}] =
        GithubCopilot.middlewares(%{copilot_token: "tid=x"})

      assert {"authorization", "Bearer tid=x"} in headers
      assert {"copilot-integration-id", "vscode-chat"} in headers
      assert {"editor-version", "vscode/1.95.0"} in headers
      assert {"editor-plugin-version", "copilot-chat/0.22.0"} in headers
      assert {"user-agent", "GitHubCopilotChat/0.22.0"} in headers
    end

    test "per-credential overrides" do
      [{Tesla.Middleware.Headers, headers}] =
        GithubCopilot.middlewares(%{
          copilot_token: "tid=x",
          editor_version: "myeditor/1.0",
          integration_id: "my-integration"
        })

      assert {"editor-version", "myeditor/1.0"} in headers
      assert {"copilot-integration-id", "my-integration"} in headers
    end

    test "returns empty list when no copilot_token" do
      assert [] == GithubCopilot.middlewares(%{})
    end
  end

  describe "registry" do
    test "is dispatched through Sycophant.Auth registry" do
      assert {:ok, GithubCopilot} = Sycophant.Registry.fetch_auth(:github_copilot)
    end
  end
end
