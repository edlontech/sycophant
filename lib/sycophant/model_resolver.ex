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
  def resolve(nil), do: {:error, Error.Invalid.MissingModel.exception([])}
  def resolve(%LLMDB.Model{} = model), do: do_resolve(model, :chat)
  def resolve(spec) when is_binary(spec), do: do_resolve_spec(spec, :chat)
  def resolve(_), do: {:error, Error.Invalid.MissingModel.exception([])}

  @spec resolve_embedding(nil | binary() | LLMDB.Model.t() | term()) ::
          {:ok, map()} | {:error, Exception.t()}
  def resolve_embedding(nil), do: {:error, Error.Invalid.MissingModel.exception([])}
  def resolve_embedding(%LLMDB.Model{} = model), do: do_resolve(model, :embedding)
  def resolve_embedding(spec) when is_binary(spec), do: do_resolve_spec(spec, :embedding)
  def resolve_embedding(_), do: {:error, Error.Invalid.MissingModel.exception([])}

  defp do_resolve(model, kind) do
    with :ok <- validate_model_kind(model, kind),
         {:ok, provider} <- fetch_provider(model.provider),
         {:ok, adapter} <- resolve_adapter(model, kind) do
      {:ok, build_info(model, provider, adapter)}
    end
  end

  defp do_resolve_spec(spec, kind) do
    case LLMDB.model(spec) do
      {:ok, model} ->
        requested_id = parse_model_id(spec)

        with {:ok, info} <- do_resolve(model, kind) do
          {:ok, maybe_override_model_id(info, model, requested_id)}
        end

      {:error, _} ->
        {:error, Error.Invalid.MissingModel.exception([])}
    end
  end

  defp validate_model_kind(_model, :chat), do: :ok

  defp validate_model_kind(%LLMDB.Model{modalities: %{output: outputs}}, :embedding) do
    if :embedding in outputs do
      :ok
    else
      {:error,
       Error.Invalid.InvalidParams.exception(errors: ["model does not support embeddings"])}
    end
  end

  defp validate_model_kind(_, :embedding) do
    {:error, Error.Invalid.InvalidParams.exception(errors: ["model does not support embeddings"])}
  end

  defp resolve_adapter(model, kind) do
    protocol =
      protocol_from_model_extra(model, kind) ||
        wire_protocol_default(model.provider, kind)

    case protocol do
      nil ->
        {:error, Error.Invalid.MissingModel.exception([])}

      protocol ->
        case Sycophant.Registry.fetch_protocol(kind, protocol) do
          {:ok, adapter} ->
            {:ok, adapter}

          :error ->
            {:error,
             Error.Unknown.Unknown.exception(error: "Unsupported #{kind} protocol: #{protocol}")}
        end
    end
  end

  defp protocol_from_model_extra(%{extra: extra}, :chat) when is_map(extra) do
    raw = get_in(extra, [:wire, :protocol]) || extra[:wire_protocol]
    to_existing_atom(raw)
  end

  defp protocol_from_model_extra(%{extra: extra}, :embedding) when is_map(extra) do
    raw = get_in(extra, [:wire, :embedding_protocol])
    to_existing_atom(raw)
  end

  defp protocol_from_model_extra(_, _), do: nil

  defp wire_protocol_default(provider, kind) do
    get_in(Sycophant.Config.wire_protocol_defaults(), [provider, kind])
  end

  defp to_existing_atom(nil), do: nil
  defp to_existing_atom(value) when is_atom(value), do: value
  defp to_existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp fetch_provider(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} -> {:ok, provider}
      {:error, _} -> {:error, Error.Invalid.MissingModel.exception([])}
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
