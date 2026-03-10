defmodule Sycophant.CredentialsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Config
  alias Sycophant.Credentials
  alias Sycophant.Error.Invalid.MissingCredentials

  setup :set_mimic_from_context
  setup :verify_on_exit!

  describe "resolve/2 with per-request credentials" do
    test "returns per-request creds when provided" do
      creds = %{api_key: "sk-per-request"}
      assert {:ok, ^creds} = Credentials.resolve(:openai, creds)
    end

    test "skips per-request when empty map" do
      stub(LLMDB, :provider, fn :unknown_provider -> {:error, :not_found} end)

      assert {:error, %MissingCredentials{}} =
               Credentials.resolve(:unknown_provider, %{})
    end
  end

  describe "resolve/2 with application config" do
    test "reads from application config" do
      expect(Config, :provider, fn :openai ->
        {:ok, %Config.Provider{api_key: "sk-from-config"}}
      end)

      assert {:ok, %{api_key: "sk-from-config"}} = Credentials.resolve(:openai)
    end

    test "skips app config when provider not configured" do
      expect(Config, :provider, fn :openai -> {:ok, %Config.Provider{}} end)
      stub(LLMDB, :provider, fn :openai -> {:error, :not_found} end)

      assert {:error, %MissingCredentials{}} = Credentials.resolve(:openai)
    end
  end

  describe "resolve/2 with environment variables" do
    test "reads from env vars using LLMDB provider.env" do
      stub(LLMDB, :provider, fn :openai ->
        {:ok, %{env: ["OPENAI_API_KEY"]}}
      end)

      expect(System, :get_env, fn "OPENAI_API_KEY" -> "sk-from-env" end)

      assert {:ok, %{api_key: "sk-from-env"}} = Credentials.resolve(:openai)
    end

    test "returns error when env var not set" do
      stub(LLMDB, :provider, fn :openai ->
        {:ok, %{env: ["OPENAI_API_KEY"]}}
      end)

      expect(System, :get_env, fn "OPENAI_API_KEY" -> nil end)

      assert {:error, %MissingCredentials{}} = Credentials.resolve(:openai)
    end
  end

  describe "resolve/2 priority" do
    test "per-request beats app config" do
      per_request = %{api_key: "sk-per-request"}
      assert {:ok, ^per_request} = Credentials.resolve(:openai, per_request)
    end

    test "app config beats env vars" do
      expect(Config, :provider, fn :openai ->
        {:ok, %Config.Provider{api_key: "sk-from-config"}}
      end)

      reject(&LLMDB.provider/1)

      assert {:ok, %{api_key: "sk-from-config"}} = Credentials.resolve(:openai)
    end
  end

  describe "resolve/2 when nothing resolves" do
    test "returns MissingCredentials error" do
      stub(LLMDB, :provider, fn :unknown -> {:error, :not_found} end)

      assert {:error, %MissingCredentials{provider: :unknown}} =
               Credentials.resolve(:unknown)
    end
  end
end
