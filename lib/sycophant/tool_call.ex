defmodule Sycophant.ToolCall do
  @moduledoc """
  Represents a tool invocation requested by the LLM.

  When an LLM decides to use a tool, it returns one or more `ToolCall` structs
  in `response.tool_calls`. Each contains a provider-assigned `:id`, the tool
  `:name`, and the parsed `:arguments` map.

  ## Examples

      iex> %Sycophant.ToolCall{id: "call_abc", name: "get_weather", arguments: %{"city" => "Paris"}}
      %Sycophant.ToolCall{id: "call_abc", name: "get_weather", arguments: %{"city" => "Paris"}}
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
