defmodule Sycophant.Auth.BedrockTest do
  use ExUnit.Case, async: true

  alias Sycophant.Auth.Bedrock

  test "produces SigV4 middleware with correct options" do
    credentials = %{
      access_key_id: "AKID",
      secret_access_key: "SECRET",
      region: "eu-west-1"
    }

    assert [
             {AwsSigV4.Middleware.SignRequest,
              [
                service: :bedrock,
                config: %{
                  region: "eu-west-1",
                  access_key_id: "AKID",
                  secret_access_key: "SECRET"
                }
              ]}
           ] = Bedrock.middlewares(credentials)
  end

  test "defaults region to us-east-1 when not provided" do
    credentials = %{access_key_id: "AKID", secret_access_key: "SECRET"}

    [{AwsSigV4.Middleware.SignRequest, sigv4_opts}] = Bedrock.middlewares(credentials)

    assert sigv4_opts[:config].region == "us-east-1"
  end

  test "includes session token as :security_token in config when provided" do
    credentials = %{
      access_key_id: "AKID",
      secret_access_key: "SECRET",
      session_token: "TOKEN"
    }

    [{AwsSigV4.Middleware.SignRequest, sigv4_opts}] = Bedrock.middlewares(credentials)

    assert sigv4_opts[:config][:security_token] == "TOKEN"
  end

  test "omits security_token when session_token not provided" do
    credentials = %{access_key_id: "AKID", secret_access_key: "SECRET"}

    [{AwsSigV4.Middleware.SignRequest, sigv4_opts}] = Bedrock.middlewares(credentials)

    refute Map.has_key?(sigv4_opts[:config], :security_token)
  end

  test "auth registry dispatches :amazon_bedrock to Bedrock module" do
    credentials = %{access_key_id: "AKID", secret_access_key: "SECRET"}

    result = Sycophant.Auth.middlewares_for(:amazon_bedrock, credentials)

    assert [{AwsSigV4.Middleware.SignRequest, _}] = result
  end

  test "path_params returns region from credentials" do
    credentials = %{region: "eu-west-1"}
    assert [region: "eu-west-1"] = Bedrock.path_params(credentials)
  end

  test "path_params defaults region to us-east-1" do
    assert [region: "us-east-1"] = Bedrock.path_params(%{})
  end

  test "path_params_for dispatches to Bedrock" do
    credentials = %{region: "ap-southeast-1"}

    assert [region: "ap-southeast-1"] =
             Sycophant.Auth.path_params_for(:amazon_bedrock, credentials)
  end

  test "path_params_for returns empty list for unknown provider" do
    assert [] = Sycophant.Auth.path_params_for(:openai, %{})
  end
end
