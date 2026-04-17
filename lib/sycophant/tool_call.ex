defmodule Sycophant.ToolCall do
  @moduledoc """
  Represents a tool invocation requested by the LLM.

  When an LLM decides to use a tool, it returns one or more `ToolCall` structs
  in `response.tool_calls`. Each contains a provider-assigned `:id`, the tool
  `:name`, and the parsed `:arguments` map.

  ## Examples

      %Sycophant.ToolCall{id: "call_abc", name: "get_weather", arguments: %{"city" => "Paris"}}
  """
  @enforce_keys [:id, :name, :arguments]
  defstruct [:id, :name, :arguments, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          metadata: map()
        }

  @doc "Reconstructs a ToolCall struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(%{"id" => id, "name" => name, "arguments" => arguments} = data) do
    %__MODULE__{
      id: id,
      name: name,
      arguments: arguments,
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.ToolCall do
  import Sycophant.Serializable.Helpers

  def to_map(%{id: id, name: name, arguments: arguments, metadata: metadata}) do
    compact(%{
      "__type__" => "ToolCall",
      "id" => id,
      "name" => name,
      "arguments" => arguments,
      "metadata" => if(map_size(metadata) > 0, do: metadata)
    })
  end
end

defimpl Inspect, for: Sycophant.ToolCall do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(tc, opts) do
    fields = %{
      id: InspectHelpers.truncate(tc.id, 15),
      name: tc.name,
      arguments: InspectHelpers.truncate_inspect(tc.arguments)
    }

    concat(["#Sycophant.ToolCall<", to_doc(fields, opts), ">"])
  end
end
