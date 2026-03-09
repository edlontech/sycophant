defmodule Sycophant.EmbeddingParams do
  @moduledoc """
  Canonical embedding parameters with Zoi validation.

  All fields are optional. Wire protocol adapters translate these into
  provider-specific parameter names and value formats.

  ## Supported Parameters

    * `:dimensions` - Desired output vector dimensionality (positive integer)
    * `:embedding_types` - List of output types (`:float`, `:int8`, `:uint8`, `:binary`, `:ubinary`). Defaults to `[:float]`
    * `:truncate` - Truncation strategy (`:none`, `:left`, `:right`). Defaults to `:none`
    * `:max_tokens` - Maximum tokens to embed per input (positive integer)
  """
  use ZoiDefstruct

  defstruct dimensions: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            embedding_types:
              Zoi.list(Zoi.enum([:float, :int8, :uint8, :binary, :ubinary]))
              |> Zoi.default([:float]),
            truncate: Zoi.enum([:none, :left, :right]) |> Zoi.default(:none),
            max_tokens: Zoi.integer() |> Zoi.positive() |> Zoi.optional()

  @doc "Deserializes embedding params from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      dimensions: data["dimensions"],
      embedding_types: decode_embedding_types(data["embedding_types"]),
      truncate: safe_atom(data["truncate"], ~w(none left right)),
      max_tokens: data["max_tokens"]
    }
  end

  @embedding_type_values ~w(float int8 uint8 binary ubinary)

  defp decode_embedding_types(nil), do: [:float]

  defp decode_embedding_types(types) when is_list(types),
    do: Enum.map(types, &safe_atom(&1, @embedding_type_values))

  defp safe_atom(nil, _allowed), do: nil

  defp safe_atom(value, allowed) do
    if value in allowed do
      String.to_existing_atom(value)
    else
      raise Sycophant.Error.Invalid.InvalidSerialization,
        reason: "invalid enum value: #{inspect(value)}, expected one of: #{inspect(allowed)}"
    end
  end
end

defimpl Sycophant.Serializable, for: Sycophant.EmbeddingParams do
  import Sycophant.Serializable.Helpers

  def to_map(params) do
    compact(%{
      "__type__" => "EmbeddingParams",
      "dimensions" => params.dimensions,
      "embedding_types" => Enum.map(params.embedding_types, &Atom.to_string/1),
      "truncate" => Atom.to_string(params.truncate),
      "max_tokens" => params.max_tokens
    })
  end
end
