defmodule Sycophant.ToolCall do
  @moduledoc """
  Represents a tool invocation requested by the LLM.

  When an LLM decides to use a tool, it returns one or more `ToolCall` structs
  in `response.tool_calls`. Each contains a provider-assigned `:id`, the tool
  `:name`, and the parsed `:arguments` map.

  ## Examples

      %Sycophant.ToolCall{id: "call_abc", name: "get_weather", arguments: %{"city" => "Paris"}}
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("ToolCall") |> Zoi.default("ToolCall"),
            id: Zoi.string(),
            name: Zoi.string(),
            arguments: Zoi.default(Zoi.any(), %{}),
            metadata: Zoi.default(Zoi.any(), %{})
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
