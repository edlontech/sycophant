defmodule Sycophant.Auth.Bedrock do
  @moduledoc """
  Authentication strategy for AWS Bedrock using SigV4 request signing.

  Produces `AwsSigV4.Middleware.SignRequest` middleware configured with
  AWS credentials. Region substitution in the base URL is handled by
  `Tesla.Middleware.PathParams` in the transport layer via `path_params`.
  """

  @behaviour Sycophant.Auth

  @default_region "us-east-1"

  @impl true
  def middlewares(credentials) do
    region = Map.get(credentials, :region, @default_region)

    sigv4_opts = [
      service: :bedrock,
      config: build_config(credentials, region)
    ]

    [{AwsSigV4.Middleware.SignRequest, sigv4_opts}]
  end

  @impl true
  def path_params(credentials) do
    [region: Map.get(credentials, :region, @default_region)]
  end

  defp build_config(credentials, region) do
    config = %{region: region}

    config =
      case Map.get(credentials, :access_key_id) do
        nil -> config
        key -> Map.put(config, :access_key_id, key)
      end

    config =
      case Map.get(credentials, :secret_access_key) do
        nil -> config
        key -> Map.put(config, :secret_access_key, key)
      end

    case Map.get(credentials, :session_token) do
      nil -> config
      token -> Map.put(config, :security_token, token)
    end
  end
end
