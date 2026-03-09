defmodule Sycophant.ResponseValidator do
  @moduledoc """
  Validates LLM response text against a Zoi schema.

  Used by `Sycophant.generate_object/3` to parse the response as JSON and
  optionally validate it against the provided schema. The validated (or raw)
  map is placed in `response.object`.

  When `:validate` is `false`, the JSON is parsed but not validated against
  the schema, allowing schema-as-hint usage where strict validation isn't needed.
  """

  alias Sycophant.Error.Invalid.InvalidResponse

  @doc "Validates and parses LLM response text against an optional schema."
  @spec validate(Sycophant.Response.t(), Zoi.schema(), boolean()) ::
          {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}
  def validate(response, schema, validate?)

  def validate(%{text: nil}, _schema, _validate?) do
    {:error, InvalidResponse.exception(errors: ["response text is nil"])}
  end

  def validate(response, schema, true) when is_map(schema) and not is_struct(schema) do
    with {:ok, decoded} <- decode_json(response.text) do
      {:ok, %{response | object: decoded}}
    end
  end

  def validate(response, schema, true) do
    with {:ok, decoded} <- decode_json(response.text),
         {:ok, validated} <- validate_schema(decoded, schema) do
      {:ok, %{response | object: validated}}
    end
  end

  def validate(response, _schema, false) do
    with {:ok, decoded} <- decode_json(response.text) do
      {:ok, %{response | object: decoded}}
    end
  end

  defp decode_json(text) do
    case JSON.decode(text) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        {:error, InvalidResponse.exception(errors: ["invalid JSON in response"])}
    end
  end

  defp validate_schema(data, schema) do
    case Zoi.parse(schema, data) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        messages = Enum.map(errors, fn err -> "#{Enum.join(err.path, ".")}: #{err.message}" end)
        {:error, InvalidResponse.exception(errors: messages)}
    end
  end
end
