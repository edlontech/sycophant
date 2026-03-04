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
    "openai_responses" => Sycophant.WireProtocol.OpenAIResponses
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
      {:ok, model} -> resolve(model)
      {:error, _} -> {:error, Error.Invalid.MissingModel.exception([])}
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
    case get_in(model.extra || %{}, [:wire, :protocol]) do
      nil ->
        {:error, Error.Invalid.MissingModel.exception([])}

      protocol when is_map_key(@adapter_map, protocol) ->
        {:ok, Map.fetch!(@adapter_map, protocol)}

      unknown ->
        {:error, Error.Unknown.Unknown.exception(error: "Unsupported wire protocol: #{unknown}")}
    end
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
end
