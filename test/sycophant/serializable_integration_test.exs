defmodule Sycophant.SerializableIntegrationTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Reasoning
  alias Sycophant.Response
  alias Sycophant.Serializable.Decoder
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  test "full multi-turn conversation round-trips" do
    response = %Response{
      text: "The weather in NYC is sunny, 72F",
      model: "claude-sonnet-4-20250514",
      usage: %Usage{input_tokens: 150, output_tokens: 50, cache_read_input_tokens: 30},
      reasoning: %Reasoning{
        content: [%Content.Thinking{text: "User asked about weather, used tool"}]
      },
      tool_calls: [],
      context: %Context{
        messages: [
          Message.system("You are a helpful assistant"),
          %Message{
            role: :user,
            content: [
              %Content.Text{text: "What's the weather like?"},
              %Content.Image{url: "https://example.com/map.png", media_type: "image/png"}
            ]
          },
          %Message{
            role: :assistant,
            content: "Let me check the weather for you.",
            tool_calls: [
              %ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "NYC"}}
            ]
          },
          Message.tool_result(
            %ToolCall{id: "call_1", name: "get_weather", arguments: %{}},
            "Sunny, 72F"
          ),
          Message.assistant("The weather in NYC is sunny, 72F")
        ],
        params: %{temperature: 0.7, reasoning: :high, stop: ["END"]},
        tools: [
          %Tool{
            name: "get_weather",
            description: "Gets current weather",
            parameters: Zoi.map(%{city: Zoi.string()}),
            function: fn args -> "Weather for #{args["city"]}" end
          }
        ]
      }
    }

    weather_fn = fn args -> "Weather for #{args["city"]}" end
    json = Decoder.encode(response)

    decoded = Decoder.decode(json, tool_registry: %{"get_weather" => weather_fn})

    assert decoded.text == response.text
    assert decoded.model == response.model
    assert decoded.usage == response.usage
    assert decoded.reasoning == response.reasoning
    assert length(decoded.context.messages) == 5
    assert decoded.context.params.temperature == 0.7
    assert decoded.context.params.reasoning in [:high, "high"]

    [tool] = decoded.context.tools
    assert tool.name == "get_weather"
    assert tool.function == weather_fn
    assert is_map(tool.parameters)

    assert decoded.context.stream == nil

    [_sys, user_msg, assistant_msg, tool_result_msg, _final] = decoded.context.messages

    assert [
             %Content.Text{text: "What's the weather like?"},
             %Content.Image{url: "https://example.com/map.png"}
           ] = user_msg.content

    assert [%ToolCall{id: "call_1", name: "get_weather"}] = assistant_msg.tool_calls
    assert tool_result_msg.role == :tool_result
    assert tool_result_msg.metadata == %{tool_name: "get_weather"}
  end

  test "JSON output is valid and parseable by external systems" do
    response = %Response{
      text: "hi",
      tool_calls: [],
      context: %Context{messages: [Message.user("hello")]}
    }

    json = Decoder.encode(response)

    assert {:ok, parsed} = JSON.decode(json)
    assert parsed["__type__"] == "Response"
    assert parsed["context"]["__type__"] == "Context"
    assert [%{"__type__" => "Message"}] = parsed["context"]["messages"]
  end
end
