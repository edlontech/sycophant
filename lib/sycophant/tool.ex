defmodule Sycophant.Tool do
  @moduledoc """
  Defines a tool that can be provided to an LLM.

  Parameters are defined as a Zoi schema, which gets converted
  to provider-specific JSON Schema by wire protocol adapters.

  When `function` is set, Sycophant will auto-execute the tool
  when the LLM returns a tool call for it. The function receives
  the parsed arguments map and returns a string result.
  When `function` is nil, tool calls are returned to the caller.
  """
  use TypedStruct

  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t(), enforce: true
    field :parameters, Zoi.schema(), enforce: true
    field :function, (map() -> String.t())
  end
end
