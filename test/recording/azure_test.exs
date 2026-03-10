defmodule Sycophant.Recording.AzureTest do
  use Sycophant.RecordingCase, async: true

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.Message

  @azure_resource System.get_env("AZURE_RESOURCE_NAME", "test-resource")

  @azure_models [
    %{
      model: "azure:gpt-5-mini",
      deployment_name: "gpt-5-mini",
      base_url_suffix: ".cognitiveservices.azure.com/openai",
      api_version: "2025-04-01-preview"
    },
    %{
      model: "azure:mistral-medium-2505",
      deployment_name: "mistral-medium-2505",
      base_url_suffix: ".services.ai.azure.com/models",
      api_version: "2024-05-01-preview"
    }
  ]

  defp azure_credentials(config) do
    creds = %{
      base_url: "https://#{@azure_resource}#{config.base_url_suffix}",
      deployment_name: config.deployment_name,
      api_version: config.api_version
    }

    case System.get_env("AZURE_API_KEY") do
      nil -> creds
      key -> Map.put(creds, :api_key, key)
    end
  end

  for azure <- @azure_models do
    model_slug = String.replace(azure.model, ":", "/")

    @tag recording: "#{model_slug}/generates_text"
    test "generates text with #{azure.model}" do
      config = unquote(Macro.escape(azure))
      messages = [Message.user("Say 'hello' and nothing else.")]

      opts = recording_opts(credentials: azure_credentials(config))

      assert {:ok, response} = Sycophant.generate_text(config.model, messages, opts)
      assert is_binary(response.text)
      assert String.length(response.text) > 0
    end

    @tag recording: "#{model_slug}/generates_text_with_system"
    test "generates text with system instructions using #{azure.model}" do
      config = unquote(Macro.escape(azure))

      messages = [
        Message.system("You are a calculator. Only respond with numbers."),
        Message.user("What is 2 + 2?")
      ]

      opts = recording_opts(credentials: azure_credentials(config))

      assert {:ok, response} = Sycophant.generate_text(config.model, messages, opts)
      assert is_binary(response.text)
      assert response.text =~ "4"
    end
  end

  @azure_embedding %{
    model: "azure:cohere-embed-v-4-0",
    deployment_name: "embed-v-4-0",
    base_url_suffix: ".services.ai.azure.com/openai/v1",
    api_version: false
  }

  @tag recording: "azure/cohere-embed-v-4-0/embeds_text"
  test "embeds text with azure:cohere-embed-v-4-0" do
    config = @azure_embedding

    request = %EmbeddingRequest{
      inputs: ["The quick brown fox jumps over the lazy dog"],
      model: config.model,
      params: %EmbeddingParams{embedding_types: [:float]}
    }

    opts =
      recording_opts(credentials: azure_credentials(config))

    assert {:ok, response} = Sycophant.embed(request, opts)
    assert is_map(response.embeddings)
    assert [vector] = response.embeddings.float
    assert is_list(vector)
    assert vector != []
    assert Enum.all?(vector, &is_float/1)
  end

  @tag recording: "azure/cohere-embed-v-4-0/embeds_multiple"
  test "embeds multiple texts with azure:cohere-embed-v-4-0" do
    config = @azure_embedding

    request = %EmbeddingRequest{
      inputs: ["first document", "second document", "third document"],
      model: config.model,
      params: %EmbeddingParams{embedding_types: [:float]}
    }

    opts =
      recording_opts(credentials: azure_credentials(config))

    assert {:ok, response} = Sycophant.embed(request, opts)
    assert length(response.embeddings.float) == 3
  end
end
