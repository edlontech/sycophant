defmodule Sycophant.Schema.Normalizer do
  @moduledoc """
  Normalizes Zoi or JSON Schema input into a `NormalizedSchema`.

  Zoi structs are converted to JSON Schema via `JsonSchema.to_json_schema/1`,
  then `additionalProperties: false` is injected recursively on object types.
  Plain maps are stringified and resolved directly without injection.
  Both paths downgrade Draft 2020-12 keywords (`prefixItems` -> `items`).
  """

  alias Sycophant.Error.Invalid.InvalidSchema
  alias Sycophant.Schema.JsonSchema
  alias Sycophant.Schema.NormalizedSchema

  @doc "Normalizes a Zoi or JSON Schema into a `NormalizedSchema` with a pre-resolved schema for validation."
  @spec normalize(Zoi.schema() | map()) ::
          {:ok, NormalizedSchema.t()} | {:error, Splode.Error.t()}
  def normalize(schema) when is_struct(schema) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(schema) do
      json_schema =
        json_schema
        |> ensure_additional_properties_false()
        |> downgrade_draft()

      resolve_and_build(json_schema, :zoi)
    end
  end

  def normalize(schema) when is_map(schema) do
    json_schema =
      schema
      |> stringify_keys()
      |> downgrade_draft()

    resolve_and_build(json_schema, :json_schema)
  end

  # Rescue is required because ExJsonSchema.Schema.resolve/1 raises on invalid
  # schemas and provides no non-raising alternative.
  defp resolve_and_build(json_schema, source) do
    resolved = ExJsonSchema.Schema.resolve(json_schema)
    {:ok, %NormalizedSchema{json_schema: json_schema, resolved: resolved, source: source}}
  rescue
    e ->
      {:error, InvalidSchema.exception(errors: [Exception.message(e)])}
  end

  defp ensure_additional_properties_false(schema) when is_map(schema) do
    schema =
      if schema["type"] == "object" and is_map(schema["properties"]) do
        Map.put(schema, "additionalProperties", false)
      else
        schema
      end

    Map.new(schema, fn
      {"properties", props} when is_map(props) ->
        {"properties",
         Map.new(props, fn {k, v} -> {k, ensure_additional_properties_false(v)} end)}

      {k, v} when is_map(v) ->
        {k, ensure_additional_properties_false(v)}

      {k, v} when is_list(v) ->
        {k,
         Enum.map(v, fn
           item when is_map(item) -> ensure_additional_properties_false(item)
           item -> item
         end)}

      pair ->
        pair
    end)
  end

  defp ensure_additional_properties_false(other), do: other

  defp downgrade_draft(schema) when is_map(schema) do
    Map.new(schema, fn
      {"prefixItems", v} -> {"items", downgrade_draft_value(v)}
      {k, v} -> {k, downgrade_draft_value(v)}
    end)
  end

  defp downgrade_draft(other), do: other

  defp downgrade_draft_value(v) when is_map(v), do: downgrade_draft(v)

  defp downgrade_draft_value(v) when is_list(v) do
    Enum.map(v, fn
      item when is_map(item) -> downgrade_draft(item)
      item -> item
    end)
  end

  defp downgrade_draft_value(v), do: v

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(atom) when is_atom(atom) and atom not in [true, false, nil] do
    Atom.to_string(atom)
  end

  defp stringify_keys(other), do: other
end
