defmodule Sycophant.ModelResolver do
  @moduledoc """
  Resolves a model specification into a normalized map containing
  everything the pipeline needs: model ID, provider, base URL,
  wire protocol adapter, environment variable names, and the raw
  LLMDB structs.

  Accepts either a `"provider:model"` string or an `%LLMDB.Model{}`
  struct. Uses LLMDB as the single source of truth.
  """

  alias Sycophant.Error

  @adapter_map %{
    "openai_chat" => Sycophant.WireProtocol.OpenAICompletions,
    "openai_responses" => Sycophant.WireProtocol.OpenAIResponses,
    "anthropic_messages" => Sycophant.WireProtocol.AnthropicMessages,
    "google_gemini" => Sycophant.WireProtocol.GoogleGemini,
    "bedrock_converse" => Sycophant.WireProtocol.BedrockConverse
  }

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
          {:ok, maybe_override_model_id(info, requested_id)}
        end

      {:error, _} ->
        {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  def resolve(_), do: {:error, Error.Invalid.MissingModel.exception([])}

  defp fetch_provider(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} -> {:ok, provider}
      {:error, _} -> {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  defp resolve_adapter(model) do
    protocol =
      get_in(model.extra || %{}, [:wire, :protocol]) ||
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

  defp maybe_override_model_id(info, requested_id) do
    if requested_id != info.model_id do
      %{info | model_id: requested_id}
    else
      info
    end
  end
end
