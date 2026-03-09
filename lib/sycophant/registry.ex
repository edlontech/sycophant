defmodule Sycophant.Registry do
  @moduledoc """
  Extensible registry for auth strategies, wire protocols, and embedding protocols.

  Built-in adapters are seeded when the Sycophant application starts.
  Library users can register additional adapters from their own
  `Application.start/2`:

      Sycophant.Registry.register_auth!(:my_provider, MyApp.Auth.Custom)
      Sycophant.Registry.register_wire_protocol!("my_proto", MyApp.WireProtocol.Custom)
      Sycophant.Registry.register_embedding_protocol!(:my_provider, MyApp.EmbeddingProto.Custom)

  Overriding a built-in key is allowed -- the last registration wins.
  """

  alias Sycophant.Error.Invalid.InvalidRegistration

  @auth_key :sycophant_auth_registry
  @wire_key :sycophant_wire_protocol_registry
  @embed_key :sycophant_embedding_protocol_registry

  @built_in_auth %{
    amazon_bedrock: Sycophant.Auth.Bedrock,
    anthropic: Sycophant.Auth.Anthropic,
    azure: Sycophant.Auth.Azure,
    google: Sycophant.Auth.Google
  }

  @built_in_wire %{
    "openai_chat" => Sycophant.WireProtocol.OpenAICompletions,
    "openai_completion" => Sycophant.WireProtocol.OpenAICompletions,
    "openai_responses" => Sycophant.WireProtocol.OpenAIResponses,
    "anthropic_messages" => Sycophant.WireProtocol.AnthropicMessages,
    "google_gemini" => Sycophant.WireProtocol.GoogleGemini,
    "bedrock_converse" => Sycophant.WireProtocol.BedrockConverse
  }

  @built_in_embed %{
    amazon_bedrock: Sycophant.EmbeddingWireProtocol.BedrockEmbed,
    azure: Sycophant.EmbeddingWireProtocol.OpenAIEmbed
  }

  @doc false
  @spec init() :: :ok
  def init do
    :persistent_term.put(@auth_key, @built_in_auth)
    :persistent_term.put(@wire_key, @built_in_wire)
    :persistent_term.put(@embed_key, @built_in_embed)
    :ok
  end

  @doc """
  Registers a custom authentication strategy for the given `provider`.

  The `module` must implement the `Sycophant.Auth` behaviour. Raises
  `Sycophant.Error.Invalid.InvalidRegistration` if it does not.

      Sycophant.Registry.register_auth!(:my_provider, MyApp.Auth.Custom)
  """
  @spec register_auth!(atom(), module()) :: :ok
  def register_auth!(provider, module) when is_atom(provider) and is_atom(module) do
    validate_behaviour!(module, Sycophant.Auth)
    update(@auth_key, provider, module)
  end

  @doc """
  Registers a custom wire protocol adapter under the given `protocol` name.

  The `module` must implement the `Sycophant.WireProtocol` behaviour. Raises
  `Sycophant.Error.Invalid.InvalidRegistration` if it does not.

      Sycophant.Registry.register_wire_protocol!("my_proto", MyApp.WireProtocol.Custom)
  """
  @spec register_wire_protocol!(String.t(), module()) :: :ok
  def register_wire_protocol!(protocol, module) when is_binary(protocol) and is_atom(module) do
    validate_behaviour!(module, Sycophant.WireProtocol)
    update(@wire_key, protocol, module)
  end

  @doc """
  Registers a custom embedding wire protocol adapter for the given `provider`.

  The `module` must implement the `Sycophant.EmbeddingWireProtocol` behaviour.
  Raises `Sycophant.Error.Invalid.InvalidRegistration` if it does not.

      Sycophant.Registry.register_embedding_protocol!(:my_provider, MyApp.Embed.Custom)
  """
  @spec register_embedding_protocol!(atom(), module()) :: :ok
  def register_embedding_protocol!(provider, module) when is_atom(provider) and is_atom(module) do
    validate_behaviour!(module, Sycophant.EmbeddingWireProtocol)
    update(@embed_key, provider, module)
  end

  @doc "Looks up the auth strategy module for `provider`."
  @spec fetch_auth(atom()) :: {:ok, module()} | :error
  def fetch_auth(provider), do: Map.fetch(:persistent_term.get(@auth_key), provider)

  @doc "Looks up the wire protocol adapter module for `protocol`."
  @spec fetch_wire_protocol(String.t()) :: {:ok, module()} | :error
  def fetch_wire_protocol(protocol), do: Map.fetch(:persistent_term.get(@wire_key), protocol)

  @doc "Looks up the embedding protocol adapter module for `provider`."
  @spec fetch_embedding_protocol(atom()) :: {:ok, module()} | :error
  def fetch_embedding_protocol(provider),
    do: Map.fetch(:persistent_term.get(@embed_key), provider)

  defp update(key, name, module) do
    current = :persistent_term.get(key)
    :persistent_term.put(key, Map.put(current, name, module))
    :ok
  end

  defp validate_behaviour!(module, behaviour) do
    case Code.ensure_loaded(module) do
      {:module, _} -> :ok
      {:error, _} -> raise InvalidRegistration, module: module, behaviour: behaviour
    end

    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless behaviour in behaviours do
      raise InvalidRegistration, module: module, behaviour: behaviour
    end
  end
end
