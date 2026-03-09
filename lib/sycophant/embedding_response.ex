defmodule Sycophant.EmbeddingResponse do
  @moduledoc """
  The result of an embedding request.

  Embeddings are always keyed by type (e.g., `:float`, `:int8`),
  even when only one type is requested.
  """
  use TypedStruct

  alias Sycophant.Usage

  typedstruct do
    field :embeddings, %{atom() => [[number()]]}, enforce: true
    field :model, String.t()
    field :usage, Usage.t()
    field :raw, map()
  end

  @allowed_types ~w(float int8 uint8 binary ubinary)

  @doc "Reconstructs an EmbeddingResponse struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      embeddings: decode_embeddings(data["embeddings"]),
      model: data["model"],
      usage: decode_usage(data["usage"]),
      raw: data["raw"]
    }
  end

  defp decode_embeddings(nil), do: %{}

  defp decode_embeddings(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      if k in @allowed_types do
        {String.to_existing_atom(k), v}
      else
        raise Sycophant.Error.Invalid.InvalidSerialization,
          reason: "invalid embedding type: #{inspect(k)}"
      end
    end)
  end

  defp decode_usage(nil), do: nil
  defp decode_usage(%{"__type__" => "Usage"} = data), do: Usage.from_map(data)
  defp decode_usage(%{"input_tokens" => _} = data), do: Usage.from_map(data)
end

defimpl Sycophant.Serializable, for: Sycophant.EmbeddingResponse do
  import Sycophant.Serializable.Helpers

  def to_map(resp) do
    compact(%{
      "__type__" => "EmbeddingResponse",
      "embeddings" => encode_embeddings(resp.embeddings),
      "model" => resp.model,
      "usage" => maybe_to_map(resp.usage),
      "raw" => resp.raw
    })
  end

  defp encode_embeddings(embeddings) do
    Map.new(embeddings, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp maybe_to_map(nil), do: nil
  defp maybe_to_map(struct), do: Sycophant.Serializable.to_map(struct)
end
