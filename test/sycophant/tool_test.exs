defmodule Sycophant.ToolTest do
  use ExUnit.Case, async: true

  alias Sycophant.Tool
  alias Sycophant.ToolCall

  describe "Tool" do
    test "constructs with name, description, and Zoi schema" do
      schema = Zoi.map(%{location: Zoi.string()})

      tool = %Tool{
        name: "get_weather",
        description: "Get the weather for a location",
        parameters: schema
      }

      assert tool.name == "get_weather"
      assert tool.description == "Get the weather for a location"
      assert tool.parameters == schema
    end
  end

  describe "ToolCall" do
    test "constructs with id, name, and arguments" do
      call = %ToolCall{
        id: "call_abc123",
        name: "get_weather",
        arguments: %{"location" => "Paris"}
      }

      assert call.id == "call_abc123"
      assert call.name == "get_weather"
      assert call.arguments == %{"location" => "Paris"}
    end
  end
end
