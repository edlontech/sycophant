defmodule Sycophant.Recording.ToolCallingTest do
  @models (for model <- Application.compile_env(:sycophant, :test_models, []) do
             %{model: model, fixture_prefix: String.replace(model, ":", "/")}
           end)

  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "calls a tool and returns tool_calls", %{model: model} do
    tool = %Sycophant.Tool{
      name: "get_weather",
      description: "Get current weather for a city",
      parameters: Zoi.map(%{city: Zoi.string()})
    }

    messages = [Message.user("What's the weather in Paris? Use the get_weather tool.")]

    {:ok, response} =
      Sycophant.generate_text(messages, recording_opts(model: model, tools: [tool]))

    assert response.tool_calls != []
    tc = hd(response.tool_calls)
    assert tc.name == "get_weather"
    assert is_map(tc.arguments)
  end

  @tag recording_prefix: true
  test "auto-executes tools with function callbacks", %{model: model} do
    tool = %Sycophant.Tool{
      name: "get_weather",
      description: "Get current weather for a city. Returns temperature and conditions.",
      parameters: Zoi.map(%{city: Zoi.string()}),
      function: fn %{"city" => city} -> "#{city}: 22C, sunny" end
    }

    messages = [Message.user("What's the weather in Paris? Use the get_weather tool.")]

    {:ok, response} =
      Sycophant.generate_text(messages, recording_opts(model: model, tools: [tool]))

    assert response.tool_calls == []
    assert is_binary(response.text)
    assert response.text =~ ~r/22|sunny|Paris/i
  end
end
