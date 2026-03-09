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
    field :parameters, Zoi.schema() | map(), enforce: true
    field :function, (map() -> String.t())
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])
    tool_registry = Keyword.get(opts, :tool_registry, %{})
    name = data["name"]

    %__MODULE__{
      name: name,
      description: data["description"],
      parameters: data["parameters"],
      function: Map.get(tool_registry, name)
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Tool do
  def to_map(%{name: name, description: desc, parameters: params}) do
    json_schema =
      case Sycophant.Schema.JsonSchema.to_json_schema(params) do
        {:ok, schema} -> schema
        _ -> params
      end

    %{
      "__type__" => "Tool",
      "name" => name,
      "description" => desc,
      "parameters" => json_schema
    }
  end
end
