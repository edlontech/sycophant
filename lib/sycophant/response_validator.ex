defmodule Sycophant.ResponseValidator do
  @moduledoc """
  Validates LLM response text against a JSON Schema.

  Used by `Sycophant.generate_object/3` to parse the response as JSON and
  optionally validate it against the provided `NormalizedSchema`. The validated
  (or raw) map is placed in `response.object`.

  When `:validate` is `false`, the JSON is parsed but not validated against
  the schema, allowing schema-as-hint usage where strict validation isn't needed.
  """

  alias Sycophant.Error.Invalid.InvalidResponse
  alias Sycophant.Schema.NormalizedSchema
  alias Sycophant.Schema.Validator

  @doc "Validates and parses LLM response text against an optional schema."
  @spec validate(Sycophant.Response.t(), NormalizedSchema.t(), boolean()) ::
          {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}
  def validate(response, schema, validate?)

  def validate(%{text: nil}, _schema, _validate?) do
    {:error, InvalidResponse.exception(errors: ["response text is nil"])}
  end

  def validate(response, schema, true) do
    with {:ok, decoded} <- decode_json(response.text),
         {:ok, validated} <- Validator.validate(schema, decoded) do
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

      {:error, error} ->
        {:error,
         InvalidResponse.exception(
           errors: ["invalid JSON in response: #{inspect(error)}\n\nPayload: #{text}"]
         )}
    end
  end
end
