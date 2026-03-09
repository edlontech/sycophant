defmodule Sycophant.Auth.Azure do
  @moduledoc """
  Authentication strategy for Azure AI Foundry.

  Uses Bearer token authentication with an api-version query parameter.
  Supports both Azure AI Foundry format (`.services.ai.azure.com`) and
  traditional Azure OpenAI format (`.openai.azure.com`).
  """

  @behaviour Sycophant.Auth

  @default_api_version "2025-04-01-preview"

  @impl true
  def middlewares(credentials) do
    bearer_middleware(credentials) ++ api_version_middleware(credentials)
  end

  @impl true
  def path_params(credentials) do
    base_url = Map.get(credentials, :base_url, "")
    deployment = Map.get(credentials, :deployment_name)

    if deployment && !uses_foundry_format?(base_url) do
      [path_prefix: "/openai/deployments/#{deployment}"]
    else
      []
    end
  end

  @doc """
  Returns `true` if the given base URL uses the Azure AI Foundry format.

  Foundry endpoints use the `.services.ai.azure.com` domain, while
  traditional Azure OpenAI endpoints use `.openai.azure.com`.
  """
  @spec uses_foundry_format?(term()) :: boolean()
  def uses_foundry_format?(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: nil} ->
        false

      %URI{host: host} ->
        String.ends_with?(host, ".services.ai.azure.com") ||
          String.ends_with?(host, ".cognitiveservices.azure.com")
    end
  end

  def uses_foundry_format?(_), do: false

  defp bearer_middleware(%{api_key: key}) when is_binary(key) do
    [{Tesla.Middleware.Headers, [{"authorization", "Bearer #{key}"}]}]
  end

  defp bearer_middleware(_), do: []

  defp api_version_middleware(%{api_version: false}), do: []

  defp api_version_middleware(credentials) do
    version = Map.get(credentials, :api_version, @default_api_version)
    [{Tesla.Middleware.Query, [{"api-version", version}]}]
  end
end
