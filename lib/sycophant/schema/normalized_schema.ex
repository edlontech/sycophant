defmodule Sycophant.Schema.NormalizedSchema do
  @moduledoc """
  Holds a normalized JSON Schema alongside its pre-resolved form and origin tag.

  Wire adapters receive `json_schema` (a plain map) for encoding.
  Validation uses `resolved` (an `ExJsonSchema.Schema.Root`).
  Key coercion to atoms is applied only when `source` is `:zoi`.
  """
  use TypedStruct

  typedstruct do
    field :json_schema, map(), enforce: true
    field :resolved, ExJsonSchema.Schema.Root.t(), enforce: true
    field :source, :zoi | :json_schema, enforce: true
  end
end
