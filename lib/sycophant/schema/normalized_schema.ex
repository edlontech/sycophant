defmodule Sycophant.Schema.NormalizedSchema do
  @moduledoc """
  Holds a normalized JSON Schema alongside its pre-resolved form and origin tag.

  Wire adapters receive `json_schema` (a plain map) for encoding.
  Validation uses `resolved` (an `ExJsonSchema.Schema.Root`).
  Key coercion to atoms is applied only when `source` is `:zoi`.
  """
  @enforce_keys [:json_schema, :resolved, :source]
  defstruct [:json_schema, :resolved, :source]

  @type t :: %__MODULE__{
          json_schema: map(),
          resolved: ExJsonSchema.Schema.Root.t(),
          source: :zoi | :json_schema
        }
end
