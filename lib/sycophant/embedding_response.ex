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
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("EmbeddingResponse") |> Zoi.default("EmbeddingResponse"),
            embeddings: Zoi.default(Zoi.any(), %{}),
            model: Zoi.optional(Zoi.string()),
            usage: Zoi.optional(Sycophant.Usage.t()),
            raw: Zoi.optional(Zoi.any())

  @allowed_types ~w(float int8 uint8 binary ubinary)

  @doc false
  @spec decode(map()) :: t()
  def decode(data) do
    resp = Zoi.parse!(__MODULE__.t(), Map.delete(data, "embeddings"))
    %{resp | embeddings: decode_embeddings(data["embeddings"])}
  end

  defp decode_embeddings(nil), do: %{}

  defp decode_embeddings(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      if key in @allowed_types do
        {String.to_existing_atom(key), v}
      else
        raise Sycophant.Error.Invalid.InvalidSerialization,
          reason: "invalid embedding type: #{inspect(key)}"
      end
    end)
  end
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
