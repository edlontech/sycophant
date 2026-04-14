defmodule Sycophant.Recording.TextToolTextTest do
  @models Sycophant.RecordingCase.test_models()
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Context
  alias Sycophant.Message

  @tag recording_prefix: true
  test "text then tool then text", %{model: model} do
    tool = %Sycophant.Tool{
      name: "get_weather",
      description: "Get current weather for a city. Returns temperature and conditions.",
      parameters: Zoi.map(%{city: Zoi.string()}),
      function: fn %{city: city} -> "#{city}: 18C, cloudy" end
    }

    # Turn 1: plain text exchange
    messages = [
      Message.system("You are a helpful assistant. Be concise."),
      Message.user("Hi! I'm planning a trip to London.")
    ]

    {:ok, resp1} = Sycophant.generate_text(model, messages, recording_opts(tools: [tool]))

    assert is_binary(resp1.text)
    assert resp1.tool_calls == []

    # Turn 2: trigger tool call (auto-executed)
    ctx =
      Context.add(
        resp1.context,
        Message.user("What's the current weather in London? Use the get_weather tool.")
      )

    {:ok, resp2} = Sycophant.generate_text(model, ctx, recording_opts(tools: [tool]))

    assert is_binary(resp2.text)
    assert resp2.text =~ "18"

    tool_result = Enum.find(Sycophant.Response.messages(resp2), &(&1.role == :tool_result))
    assert tool_result, "expected tool_result message in conversation history"
    assert tool_result.content == "London: 18C, cloudy"

    # Turn 3: follow-up text without tool use
    ctx2 =
      Context.add(resp2.context, Message.user("Thanks! Should I bring an umbrella?"))

    {:ok, resp3} = Sycophant.generate_text(model, ctx2, recording_opts(tools: [tool]))

    assert is_binary(resp3.text)
    assert resp3.tool_calls == []

    history = Sycophant.Response.messages(resp3)
    assert length(history) >= 6
  end
end
