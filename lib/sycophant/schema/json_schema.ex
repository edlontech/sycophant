defmodule Sycophant.Schema.JsonSchema do
  @moduledoc """
  Converts Zoi schemas to JSON Schema maps.

  Wraps `Zoi.to_json_schema/1` with normalization: atom keys and values
  are converted to strings, and the `$schema` meta-reference is stripped.
  Wire protocol adapters call this for tool parameters and response schemas.
  """

  alias Sycophant.Error.Invalid.InvalidSchema

  @doc "Converts a Zoi schema to a normalized JSON Schema map."
  @spec to_json_schema(Zoi.schema() | map()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def to_json_schema(schema) when is_map(schema) and not is_struct(schema) do
    {:ok, schema}
  end

  def to_json_schema(schema) do
    {:ok, schema |> Zoi.to_json_schema() |> normalize()}
  rescue
    e in ArgumentError ->
      {:error, InvalidSchema.exception(errors: [e.message])}
  end

  defp normalize(map) when is_map(map) do
    map
    |> Map.delete(:"$schema")
    |> Map.delete("$schema")
    |> Map.new(fn {k, v} -> {stringify_key(k), normalize(v)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(atom) when is_atom(atom) and atom not in [true, false, nil] do
    Atom.to_string(atom)
  end

  defp normalize(value), do: value

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_binary(key), do: key
end
