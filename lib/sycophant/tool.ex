defmodule Sycophant.Tool do
  @moduledoc """
  Defines a tool that can be provided to an LLM.

  Parameters are defined as a Zoi schema, which gets converted
  to provider-specific JSON Schema by wire protocol adapters.
  """
  use TypedStruct

  typedstruct do
    field(:name, String.t(), enforce: true)
    field(:description, String.t(), enforce: true)
    field(:parameters, Zoi.schema(), enforce: true)
  end
end
