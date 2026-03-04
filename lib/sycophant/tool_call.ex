defmodule Sycophant.ToolCall do
  @moduledoc """
  Represents a tool invocation requested by the LLM.

  Contains the provider-assigned call ID, the tool name,
  and the parsed arguments map. Argument validation against
  the Tool's Zoi schema is the caller's responsibility.
  """
  use TypedStruct

  typedstruct do
    field :id, String.t(), enforce: true
    field :name, String.t(), enforce: true
    field :arguments, map(), enforce: true
  end
end
