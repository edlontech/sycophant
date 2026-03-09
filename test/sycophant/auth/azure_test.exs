defmodule Sycophant.Auth.AzureTest do
  use ExUnit.Case, async: true

  alias Sycophant.Auth
  alias Sycophant.Auth.Azure

  describe "middlewares/1" do
    test "returns Bearer header middleware when api_key present" do
      middlewares = Azure.middlewares(%{api_key: "test-key"})

      assert {Tesla.Middleware.Headers, [{"authorization", "Bearer test-key"}]} in middlewares
    end

    test "returns api_version Query middleware with default version" do
      middlewares = Azure.middlewares(%{api_key: "test-key"})

      assert {Tesla.Middleware.Query, [{"api-version", "2025-04-01-preview"}]} in middlewares
    end

    test "uses custom api_version from credentials" do
      middlewares = Azure.middlewares(%{api_key: "test-key", api_version: "2025-01-01"})

      assert {Tesla.Middleware.Query, [{"api-version", "2025-01-01"}]} in middlewares
    end

    test "returns only api_version middleware when no api_key" do
      middlewares = Azure.middlewares(%{})

      assert [{Tesla.Middleware.Query, [{"api-version", "2025-04-01-preview"}]}] == middlewares
    end

    test "skips api_version middleware when api_version is false" do
      middlewares = Azure.middlewares(%{api_key: "test-key", api_version: false})

      assert [{Tesla.Middleware.Headers, [{"authorization", "Bearer test-key"}]}] == middlewares
    end
  end

  describe "path_params/1" do
    test "returns empty list when no deployment_name" do
      assert [] == Azure.path_params(%{})
      assert [] == Azure.path_params(%{api_key: "key"})
    end

    test "returns path_prefix with deployment_name for traditional format" do
      params =
        Azure.path_params(%{
          deployment_name: "my-gpt4o",
          base_url: "https://my-resource.openai.azure.com"
        })

      assert [path_prefix: "/openai/deployments/my-gpt4o"] == params
    end

    test "returns empty list with deployment_name for foundry format" do
      assert [] ==
               Azure.path_params(%{
                 deployment_name: "my-gpt4o",
                 base_url: "https://my-project.services.ai.azure.com"
               })

      assert [] ==
               Azure.path_params(%{
                 deployment_name: "my-gpt4o",
                 base_url: "https://my-project.cognitiveservices.azure.com"
               })
    end
  end

  describe "uses_foundry_format?/1" do
    test "returns true for .services.ai.azure.com hosts" do
      assert Azure.uses_foundry_format?("https://my-project.services.ai.azure.com")
      assert Azure.uses_foundry_format?("https://foo.services.ai.azure.com/openai/deployments")
    end

    test "returns true for .cognitiveservices.azure.com hosts" do
      assert Azure.uses_foundry_format?("https://my-resource.cognitiveservices.azure.com")
    end

    test "returns false for .openai.azure.com hosts" do
      refute Azure.uses_foundry_format?("https://my-resource.openai.azure.com")
    end

    test "returns false for nil and non-string input" do
      refute Azure.uses_foundry_format?(nil)
      refute Azure.uses_foundry_format?(123)
    end
  end

  describe "auth registry" do
    test "dispatches to Auth.Azure for :azure provider" do
      middlewares = Auth.middlewares_for(:azure, %{api_key: "test-key"})

      assert {Tesla.Middleware.Headers, [{"authorization", "Bearer test-key"}]} in middlewares
      assert {Tesla.Middleware.Query, [{"api-version", "2025-04-01-preview"}]} in middlewares
    end
  end
end
