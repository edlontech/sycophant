defmodule Sycophant.Config.ProviderTest do
  use ExUnit.Case, async: true

  alias Sycophant.Config.Provider

  describe "Provider schema" do
    test "parses base_url, deployment_name, and api_version" do
      input = %{
        api_key: "sk-azure",
        base_url: "https://my-resource.openai.azure.com",
        deployment_name: "gpt-4",
        api_version: "2024-02-01"
      }

      assert {:ok, %Provider{} = provider} = Zoi.parse(Provider.t(), input)
      assert provider.api_key == "sk-azure"
      assert provider.base_url == "https://my-resource.openai.azure.com"
      assert provider.deployment_name == "gpt-4"
      assert provider.api_version == "2024-02-01"
    end

    test "new fields are optional" do
      assert {:ok, %Provider{} = provider} = Zoi.parse(Provider.t(), %{api_key: "sk-test"})
      assert is_nil(provider.base_url)
      assert is_nil(provider.deployment_name)
      assert is_nil(provider.api_version)
    end

    test "existing fields still work without new fields" do
      input = %{
        api_key: "sk-test",
        api_secret: "secret",
        region: "us-east-1",
        access_key_id: "AKIA...",
        secret_access_key: "wJa..."
      }

      assert {:ok, %Provider{} = provider} = Zoi.parse(Provider.t(), input)
      assert provider.api_key == "sk-test"
      assert provider.region == "us-east-1"
      assert is_nil(provider.base_url)
    end
  end

  describe "Provider — Copilot fields" do
    test "parses github_token, copilot_token, github_host, editor_*, integration_id" do
      Application.put_env(:sycophant, :providers,
        github_copilot: [
          github_token: "ghp_x",
          copilot_token: "tid=y",
          github_host: "ghe.example.com",
          editor_version: "vscode/1.95.0",
          editor_plugin_version: "copilot-chat/0.22.0",
          integration_id: "vscode-chat"
        ]
      )

      {:ok, config} = Sycophant.Config.provider(:github_copilot)
      assert config.github_token == "ghp_x"
      assert config.copilot_token == "tid=y"
      assert config.github_host == "ghe.example.com"
      assert config.editor_version == "vscode/1.95.0"
      assert config.editor_plugin_version == "copilot-chat/0.22.0"
      assert config.integration_id == "vscode-chat"
    end

    test "Inspect redacts github_token and copilot_token" do
      Application.put_env(:sycophant, :providers,
        github_copilot: [github_token: "ghp_secret", copilot_token: "tid=secret"]
      )

      {:ok, config} = Sycophant.Config.provider(:github_copilot)
      rendered = inspect(config)
      assert rendered =~ "REDACTED"
      refute rendered =~ "ghp_secret"
      refute rendered =~ "tid=secret"
    end
  end
end
