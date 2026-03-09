defmodule Sycophant.RegistryTest do
  use ExUnit.Case, async: false

  alias Sycophant.Error.Invalid.InvalidRegistration
  alias Sycophant.Registry

  setup do
    Registry.init()
    :ok
  end

  describe "init/0" do
    test "seeds built-in auth strategies" do
      assert {:ok, Sycophant.Auth.Bedrock} = Registry.fetch_auth(:amazon_bedrock)
      assert {:ok, Sycophant.Auth.Anthropic} = Registry.fetch_auth(:anthropic)
      assert {:ok, Sycophant.Auth.Azure} = Registry.fetch_auth(:azure)
      assert {:ok, Sycophant.Auth.Google} = Registry.fetch_auth(:google)
    end

    test "seeds built-in wire protocols" do
      assert {:ok, Sycophant.WireProtocol.OpenAICompletions} =
               Registry.fetch_wire_protocol("openai_chat")

      assert {:ok, Sycophant.WireProtocol.OpenAICompletions} =
               Registry.fetch_wire_protocol("openai_completion")

      assert {:ok, Sycophant.WireProtocol.OpenAIResponses} =
               Registry.fetch_wire_protocol("openai_responses")

      assert {:ok, Sycophant.WireProtocol.AnthropicMessages} =
               Registry.fetch_wire_protocol("anthropic_messages")

      assert {:ok, Sycophant.WireProtocol.GoogleGemini} =
               Registry.fetch_wire_protocol("google_gemini")

      assert {:ok, Sycophant.WireProtocol.BedrockConverse} =
               Registry.fetch_wire_protocol("bedrock_converse")
    end

    test "seeds built-in embedding protocols" do
      assert {:ok, Sycophant.EmbeddingWireProtocol.BedrockEmbed} =
               Registry.fetch_embedding_protocol(:amazon_bedrock)

      assert {:ok, Sycophant.EmbeddingWireProtocol.OpenAIEmbed} =
               Registry.fetch_embedding_protocol(:azure)
    end
  end

  describe "register_auth!/2" do
    test "registers a valid auth module" do
      Registry.register_auth!(:custom, Sycophant.Auth.Google)
      assert {:ok, Sycophant.Auth.Google} = Registry.fetch_auth(:custom)
    end

    test "overrides existing registration" do
      Registry.register_auth!(:google, Sycophant.Auth.Bearer)
      assert {:ok, Sycophant.Auth.Bearer} = Registry.fetch_auth(:google)
    end

    test "raises InvalidRegistration for non-implementing module" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_auth!(:bad, String)
      end
    end
  end

  describe "register_wire_protocol!/2" do
    test "registers a valid wire protocol module" do
      Registry.register_wire_protocol!("custom", Sycophant.WireProtocol.GoogleGemini)

      assert {:ok, Sycophant.WireProtocol.GoogleGemini} =
               Registry.fetch_wire_protocol("custom")
    end

    test "raises InvalidRegistration for non-implementing module" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_wire_protocol!("bad", String)
      end
    end
  end

  describe "register_embedding_protocol!/2" do
    test "registers a valid embedding protocol module" do
      Registry.register_embedding_protocol!(:custom, Sycophant.EmbeddingWireProtocol.OpenAIEmbed)

      assert {:ok, Sycophant.EmbeddingWireProtocol.OpenAIEmbed} =
               Registry.fetch_embedding_protocol(:custom)
    end

    test "raises InvalidRegistration for non-implementing module" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_embedding_protocol!(:bad, String)
      end
    end
  end

  describe "fetch_*/1 returns :error for unknown keys" do
    test "fetch_auth" do
      assert :error = Registry.fetch_auth(:nonexistent)
    end

    test "fetch_wire_protocol" do
      assert :error = Registry.fetch_wire_protocol("nonexistent")
    end

    test "fetch_embedding_protocol" do
      assert :error = Registry.fetch_embedding_protocol(:nonexistent)
    end
  end
end
