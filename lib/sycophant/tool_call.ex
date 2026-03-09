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

  @doc "Reconstructs a ToolCall struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(%{"id" => id, "name" => name, "arguments" => arguments}) do
    %__MODULE__{id: id, name: name, arguments: arguments}
  end
end

defimpl Sycophant.Serializable, for: Sycophant.ToolCall do
  def to_map(%{id: id, name: name, arguments: arguments}) do
    %{"__type__" => "ToolCall", "id" => id, "name" => name, "arguments" => arguments}
  end
end
