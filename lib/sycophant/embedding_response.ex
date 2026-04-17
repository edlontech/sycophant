defmodule Sycophant.EmbeddingResponse do
  @moduledoc """
  The result of an embedding request.

  Embeddings are keyed by type (e.g., `:float`, `:int8`), even when only
  one type is requested. Each value is a list of vectors corresponding
  to the input order.

  ## Examples

      {:ok, response} = Sycophant.embed(request)

      # Access float embeddings
      [first_vector | _rest] = response.embeddings.float
      length(first_vector)
      #=> 1024

      # Multiple types when requested
      response.embeddings
      #=> %{float: [[0.1, ...], [0.2, ...]], int8: [[12, ...], [34, ...]]}
  """
  alias Sycophant.Usage

  @enforce_keys [:embeddings]
  defstruct [:embeddings, :model, :usage, :raw]

  @type t :: %__MODULE__{
          embeddings: %{atom() => [[number()]]},
          model: String.t() | nil,
          usage: Usage.t() | nil,
          raw: map() | nil
        }

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

defimpl Inspect, for: Sycophant.EmbeddingResponse do
  import Inspect.Algebra

  def inspect(resp, opts) do
    types = Map.keys(resp.embeddings)
    count = resp.embeddings |> Map.values() |> List.first([]) |> length()

    fields =
      Enum.reject(
        [
          model: resp.model,
          types: types,
          vectors: count,
          usage: resp.usage
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.EmbeddingResponse<", to_doc(Map.new(fields), opts), ">"])
  end
end
