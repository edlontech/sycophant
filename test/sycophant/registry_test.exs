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

    test "seeds built-in chat protocols" do
      assert {:ok, Sycophant.WireProtocol.OpenAICompletions} =
               Registry.fetch_protocol(:chat, :openai_chat)

      assert {:ok, Sycophant.WireProtocol.OpenAICompletions} =
               Registry.fetch_protocol(:chat, :openai_completion)

      assert {:ok, Sycophant.WireProtocol.OpenAIResponses} =
               Registry.fetch_protocol(:chat, :openai_responses)

      assert {:ok, Sycophant.WireProtocol.AnthropicMessages} =
               Registry.fetch_protocol(:chat, :anthropic_messages)

      assert {:ok, Sycophant.WireProtocol.GoogleGemini} =
               Registry.fetch_protocol(:chat, :google_gemini)

      assert {:ok, Sycophant.WireProtocol.BedrockConverse} =
               Registry.fetch_protocol(:chat, :bedrock_converse)
    end

    test "seeds built-in embedding protocols" do
      assert {:ok, Sycophant.EmbeddingWireProtocol.OpenAIEmbed} =
               Registry.fetch_protocol(:embedding, :openai_embed)

      assert {:ok, Sycophant.EmbeddingWireProtocol.BedrockEmbed} =
               Registry.fetch_protocol(:embedding, :bedrock_embed)
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

  describe "register_protocol!/3" do
    test "registers a valid chat module" do
      Registry.register_protocol!(:chat, :custom, Sycophant.WireProtocol.GoogleGemini)

      assert {:ok, Sycophant.WireProtocol.GoogleGemini} =
               Registry.fetch_protocol(:chat, :custom)
    end

    test "registers a valid embedding module" do
      Registry.register_protocol!(
        :embedding,
        :custom,
        Sycophant.EmbeddingWireProtocol.OpenAIEmbed
      )

      assert {:ok, Sycophant.EmbeddingWireProtocol.OpenAIEmbed} =
               Registry.fetch_protocol(:embedding, :custom)
    end

    test "overrides existing registration" do
      Registry.register_protocol!(:chat, :openai_chat, Sycophant.WireProtocol.GoogleGemini)

      assert {:ok, Sycophant.WireProtocol.GoogleGemini} =
               Registry.fetch_protocol(:chat, :openai_chat)
    end

    test "raises InvalidRegistration for non-implementing chat module" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_protocol!(:chat, :bad, String)
      end
    end

    test "raises InvalidRegistration for non-implementing embedding module" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_protocol!(:embedding, :bad, String)
      end
    end

    test "raises InvalidRegistration for cross-kind mismatch" do
      assert_raise InvalidRegistration, fn ->
        Registry.register_protocol!(:embedding, :bad, Sycophant.WireProtocol.OpenAICompletions)
      end
    end
  end

  describe "fetch_protocol/2" do
    test "returns :error for unknown chat key" do
      assert :error = Registry.fetch_protocol(:chat, :nonexistent)
    end

    test "returns :error for unknown embedding key" do
      assert :error = Registry.fetch_protocol(:embedding, :nonexistent)
    end
  end

  describe "fetch_auth/1" do
    test "returns :error for unknown key" do
      assert :error = Registry.fetch_auth(:nonexistent)
    end
  end
end
