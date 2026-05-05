defmodule Sycophant.AuthTest do
  use ExUnit.Case, async: true

  alias Sycophant.Auth

  describe "prepare_credentials_for/2" do
    test "returns credentials unchanged for providers without an impl" do
      creds = %{api_key: "sk-test"}
      assert {:ok, ^creds} = Auth.prepare_credentials_for(:openai, creds)
    end

    test "returns credentials unchanged for unregistered providers" do
      creds = %{api_key: "x"}
      assert {:ok, ^creds} = Auth.prepare_credentials_for(:nonexistent_provider, creds)
    end
  end
end
