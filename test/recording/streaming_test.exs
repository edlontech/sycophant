defmodule Sycophant.Recording.StreamingTest do
  @models Sycophant.RecordingCase.test_models()
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "streams text", %{model: model} do
    test_pid = self()

    callback = fn chunk ->
      send(test_pid, {:chunk, chunk})
    end

    messages = [Message.user("Say 'hello' and nothing else.")]

    assert {:ok, response} =
             Sycophant.generate_text(
               model,
               messages,
               recording_opts(stream: callback)
             )

    assert is_binary(response.text)
    assert String.length(response.text) > 0

    assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta}}
  end

  @tag recording_prefix: true
  test "streams with tool auto-execution", %{model: model} do
    test_pid = self()

    callback = fn chunk ->
      send(test_pid, {:chunk, chunk})
    end

    tool = %Sycophant.Tool{
      name: "get_weather",
      description: "Get current weather for a city. Returns temperature and conditions.",
      parameters: Zoi.map(%{city: Zoi.string()}),
      function: fn %{"city" => city} -> "#{city}: 22C, sunny" end
    }

    messages = [Message.user("What's the weather in Paris? Use the get_weather tool.")]

    assert {:ok, response} =
             Sycophant.generate_text(
               model,
               messages,
               recording_opts(tools: [tool], stream: callback)
             )

    assert response.tool_calls == []
    assert is_binary(response.text)
    assert response.text =~ ~r/22|sunny|Paris/i

    assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta}}
  end
end
