defmodule Sycophant.ModelResolver do
  @moduledoc """
  Resolves model identifiers into pipeline-ready metadata.

  Takes a model specification (e.g., `"openai:gpt-4o-mini"`) and returns
  a normalized map containing everything the pipeline needs: model ID,
  provider atom, base URL, wire protocol adapter module, and the raw
  LLMDB structs.

  ## Model Specification Format

  Models are identified as `"provider:model_id"` strings:

    * `"openai:gpt-4o-mini"` - OpenAI GPT-4o Mini
    * `"anthropic:claude-haiku-4-5-20251001"` - Anthropic Claude Haiku
    * `"amazon_bedrock:anthropic.claude-3-5-sonnet-20241022-v2:0"` - Bedrock Claude
    * `"google:gemini-2.0-flash"` - Google Gemini
    * `"azure:gpt-4o"` - Azure OpenAI

  Model metadata is sourced from LLMDB as the single source of truth.
  """

  alias Sycophant.Error

  @embedding_adapters %{
    amazon_bedrock: Sycophant.EmbeddingWireProtocol.BedrockEmbed,
    azure: Sycophant.EmbeddingWireProtocol.OpenAIEmbed
  }

  @adapter_map %{
    "openai_chat" => Sycophant.WireProtocol.OpenAICompletions,
    "openai_completion" => Sycophant.WireProtocol.OpenAICompletions,
    "openai_responses" => Sycophant.WireProtocol.OpenAIResponses,
    "anthropic_messages" => Sycophant.WireProtocol.AnthropicMessages,
    "google_gemini" => Sycophant.WireProtocol.GoogleGemini,
    "bedrock_converse" => Sycophant.WireProtocol.BedrockConverse
  }

  @doc """
  Resolves a model specification into a normalized map for the pipeline.

  Accepts a `"provider:model"` string, an `%LLMDB.Model{}` struct, or `nil`.
  Looks up the model and its provider in LLMDB, selects the appropriate wire
  protocol adapter, and returns a map with `:model_id`, `:provider`,
  `:base_url`, `:wire_adapter`, `:env_vars`, and the raw LLMDB structs.
  When a string spec contains a model ID that differs from the canonical one,
  the requested ID takes precedence.
  """
  @spec resolve(nil | binary() | LLMDB.Model.t() | term()) ::
          {:ok, map()} | {:error, Exception.t()}
  def resolve(nil) do
    {:error, Error.Invalid.MissingModel.exception([])}
  end

  def resolve(%LLMDB.Model{} = model) do
    with {:ok, provider} <- fetch_provider(model.provider),
         {:ok, adapter} <- resolve_adapter(model) do
      {:ok, build_info(model, provider, adapter)}
    end
  end

  def resolve(spec) when is_binary(spec) do
    case LLMDB.model(spec) do
      {:ok, model} ->
        requested_id = parse_model_id(spec)

        with {:ok, info} <- resolve(model) do
          {:ok, maybe_override_model_id(info, model, requested_id)}
        end

      {:error, _} ->
        {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  def resolve(_), do: {:error, Error.Invalid.MissingModel.exception([])}

  @spec resolve_embedding(nil | binary() | LLMDB.Model.t() | term()) ::
          {:ok, map()} | {:error, Exception.t()}
  def resolve_embedding(nil) do
    {:error, Error.Invalid.MissingModel.exception([])}
  end

  def resolve_embedding(%LLMDB.Model{} = model) do
    with :ok <- validate_embedding_model(model),
         {:ok, provider} <- fetch_provider(model.provider),
         {:ok, adapter} <- resolve_embedding_adapter(model.provider) do
      {:ok, build_info(model, provider, adapter)}
    end
  end

  def resolve_embedding(spec) when is_binary(spec) do
    case LLMDB.model(spec) do
      {:ok, model} ->
        requested_id = parse_model_id(spec)

        with {:ok, info} <- resolve_embedding(model) do
          {:ok, maybe_override_model_id(info, model, requested_id)}
        end

      {:error, _} ->
        {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  def resolve_embedding(_), do: {:error, Error.Invalid.MissingModel.exception([])}

  defp validate_embedding_model(%LLMDB.Model{modalities: %{output: outputs}}) do
    if :embedding in outputs do
      :ok
    else
      {:error,
       Error.Invalid.InvalidParams.exception(errors: ["model does not support embeddings"])}
    end
  end

  defp validate_embedding_model(_) do
    {:error, Error.Invalid.InvalidParams.exception(errors: ["model does not support embeddings"])}
  end

  defp resolve_embedding_adapter(provider) do
    case Map.fetch(@embedding_adapters, provider) do
      {:ok, adapter} ->
        {:ok, adapter}

      :error ->
        {:error,
         Error.Unknown.Unknown.exception(error: "No embedding adapter for provider: #{provider}")}
    end
  end

  defp fetch_provider(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} -> {:ok, provider}
      {:error, _} -> {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  defp resolve_adapter(model) do
    extra = model.extra || %{}

    protocol =
      get_in(extra, [:wire, :protocol]) ||
        extra[:wire_protocol] ||
        wire_protocol_default(model.provider)

    case protocol do
      nil ->
        {:error, Error.Invalid.MissingModel.exception([])}

      protocol when is_map_key(@adapter_map, protocol) ->
        {:ok, Map.fetch!(@adapter_map, protocol)}

      unknown ->
        {:error, Error.Unknown.Unknown.exception(error: "Unsupported wire protocol: #{unknown}")}
    end
  end

  defp wire_protocol_default(provider) do
    :sycophant
    |> Application.get_env(:wire_protocol_defaults, %{})
    |> Map.get(provider)
  end

  defp build_info(model, provider, adapter) do
    %{
      model_id: model.provider_model_id || model.id,
      provider: model.provider,
      base_url: model.base_url || provider.base_url,
      wire_adapter: adapter,
      env_vars: provider.env || [],
      model_struct: model,
      provider_struct: provider
    }
  end

  defp parse_model_id(spec) do
    case String.split(spec, ":", parts: 2) do
      [_provider, model_id] -> model_id
      _ -> spec
    end
  end

  defp maybe_override_model_id(info, model, requested_id) do
    if requested_id != info.model_id and requested_id != model.id do
      %{info | model_id: requested_id}
    else
      info
    end
  end
end
