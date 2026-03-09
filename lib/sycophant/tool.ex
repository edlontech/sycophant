defmodule Sycophant.Tool do
  @moduledoc """
  Defines a tool that can be provided to an LLM.

  Tools describe callable functions that the LLM can invoke during generation.
  Parameters are defined as a Zoi schema, which wire protocol adapters convert
  to provider-specific JSON Schema.

  ## Auto-execution

  When `function` is set, Sycophant automatically executes the tool when the
  LLM returns a tool call, feeds the result back, and continues the loop
  (up to `:max_steps` iterations). When `function` is `nil`, tool calls are
  returned in `response.tool_calls` for manual handling.

  ## Examples

      # Auto-executed tool
      weather_tool = %Sycophant.Tool{
        name: "get_weather",
        description: "Get current weather for a city",
        parameters: Zoi.object(%{city: Zoi.string()}),
        function: fn %{"city" => city} -> "72F and sunny in \#{city}" end
      }

      # Manual tool (no function)
      search_tool = %Sycophant.Tool{
        name: "search",
        description: "Search the web",
        parameters: Zoi.object(%{query: Zoi.string()})
      }

      {:ok, response} = Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        tools: [weather_tool, search_tool]
      )
  """
  use TypedStruct

  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t(), enforce: true
    field :parameters, Zoi.schema() | map(), enforce: true
    field :function, (map() -> String.t())
  end

  @doc "Reconstructs a Tool struct from a serialized map."
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
