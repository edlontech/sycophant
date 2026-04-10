defmodule Sycophant.Registry do
  @moduledoc """
  Extensible registry for auth strategies and wire protocols.

  Built-in adapters are seeded when the Sycophant application starts.
  Library users can register additional adapters from their own
  `Application.start/2`:

      Sycophant.Registry.register_auth!(:my_provider, MyApp.Auth.Custom)
      Sycophant.Registry.register_protocol!(:chat, :my_proto, MyApp.WireProtocol.Custom)
      Sycophant.Registry.register_protocol!(:embedding, :my_embed, MyApp.EmbeddingProto.Custom)

  Overriding a built-in key is allowed -- the last registration wins.
  """

  alias Sycophant.Error.Invalid.InvalidRegistration

  @auth_key :sycophant_auth_registry
  @protocol_key :sycophant_protocol_registry

  @built_in_auth %{
    amazon_bedrock: Sycophant.Auth.Bedrock,
    anthropic: Sycophant.Auth.Anthropic,
    azure: Sycophant.Auth.Azure,
    google: Sycophant.Auth.Google
  }

  @built_in_protocols %{
    {:chat, :openai_chat} => Sycophant.WireProtocol.OpenAICompletions,
    {:chat, :openai_completion} => Sycophant.WireProtocol.OpenAICompletions,
    {:chat, :openai_responses} => Sycophant.WireProtocol.OpenAIResponses,
    {:chat, :anthropic_messages} => Sycophant.WireProtocol.AnthropicMessages,
    {:chat, :google_gemini} => Sycophant.WireProtocol.GoogleGemini,
    {:chat, :bedrock_converse} => Sycophant.WireProtocol.BedrockConverse,
    {:embedding, :openai_embed} => Sycophant.EmbeddingWireProtocol.OpenAIEmbed,
    {:embedding, :bedrock_embed} => Sycophant.EmbeddingWireProtocol.BedrockEmbed
  }

  @type kind :: :chat | :embedding

  @doc false
  @spec init() :: :ok
  def init do
    :persistent_term.put(@auth_key, @built_in_auth)
    :persistent_term.put(@protocol_key, @built_in_protocols)
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
  Registers a custom protocol adapter under the given `kind` and `protocol_name`.

  The `module` must implement `Sycophant.WireProtocol` for `:chat` kind or
  `Sycophant.EmbeddingWireProtocol` for `:embedding` kind. Raises
  `Sycophant.Error.Invalid.InvalidRegistration` if it does not.

      Sycophant.Registry.register_protocol!(:chat, :my_proto, MyApp.WireProtocol.Custom)
      Sycophant.Registry.register_protocol!(:embedding, :my_embed, MyApp.EmbeddingProto.Custom)
  """
  @spec register_protocol!(kind(), atom(), module()) :: :ok
  def register_protocol!(kind, protocol_name, module)
      when kind in [:chat, :embedding] and is_atom(protocol_name) and is_atom(module) do
    validate_behaviour!(module, behaviour_for_kind(kind))
    update(@protocol_key, {kind, protocol_name}, module)
  end

  @doc "Looks up the auth strategy module for `provider`."
  @spec fetch_auth(atom()) :: {:ok, module()} | :error
  def fetch_auth(provider), do: Map.fetch(:persistent_term.get(@auth_key), provider)

  @doc "Looks up the protocol adapter module for the given `kind` and `protocol_name`."
  @spec fetch_protocol(kind(), atom()) :: {:ok, module()} | :error
  def fetch_protocol(kind, protocol_name) do
    Map.fetch(:persistent_term.get(@protocol_key), {kind, protocol_name})
  end

  defp update(key, name, module) do
    current = :persistent_term.get(key)
    :persistent_term.put(key, Map.put(current, name, module))
    :ok
  end

  defp behaviour_for_kind(:chat), do: Sycophant.WireProtocol
  defp behaviour_for_kind(:embedding), do: Sycophant.EmbeddingWireProtocol

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
