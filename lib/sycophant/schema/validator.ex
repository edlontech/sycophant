defmodule Sycophant.Schema.Validator do
  @moduledoc """
  Validates JSON-decoded data against a `NormalizedSchema` using `ex_json_schema`.

  For Zoi-sourced schemas, string keys are coerced to atoms by walking the
  JSON Schema `properties`. Keys without a pre-existing atom are kept as strings.
  JSON Schema-sourced data is returned as-is with string keys.
  """

  alias Sycophant.Error.Invalid.InvalidResponse
  alias Sycophant.Schema.NormalizedSchema

  @doc "Validates JSON-decoded data against a NormalizedSchema. Coerces keys to atoms for Zoi-sourced schemas."
  @spec validate(NormalizedSchema.t(), map()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def validate(
        %NormalizedSchema{resolved: resolved, source: source, json_schema: json_schema},
        data
      ) do
    case ExJsonSchema.Validator.validate(resolved, data) do
      :ok ->
        {:ok, maybe_coerce_keys(data, json_schema, source)}

      {:error, errors} ->
        messages = Enum.map(errors, fn {msg, path} -> "#{path}: #{msg}" end)
        {:error, InvalidResponse.exception(errors: messages)}
    end
  end

  defp maybe_coerce_keys(data, _json_schema, :json_schema), do: data

  defp maybe_coerce_keys(data, json_schema, :zoi) do
    coerce_keys(data, json_schema)
  end

  defp coerce_keys(data, schema) when is_map(data) and is_map(schema) do
    properties = Map.get(schema, "properties", %{})

    Map.new(data, fn {key, value} ->
      coerced_key = safe_to_atom(key)
      child_schema = Map.get(properties, key, %{})
      {coerced_key, coerce_value(value, child_schema)}
    end)
  end

  defp coerce_keys(data, _schema), do: data

  defp coerce_value(value, schema) when is_map(value) and is_map(schema) do
    coerce_keys(value, schema)
  end

  defp coerce_value(value, %{"type" => "array", "items" => item_schema}) when is_list(value) do
    Enum.map(value, &coerce_value(&1, item_schema))
  end

  defp coerce_value(value, _schema), do: value

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
