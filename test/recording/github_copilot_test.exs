defmodule Sycophant.Recording.GithubCopilotTest do
  @models Enum.filter(
            Sycophant.RecordingCase.test_models(),
            &String.starts_with?(&1.model, "github_copilot:")
          )

  use Sycophant.RecordingCase, async: false, parameterize: @models

  alias Sycophant.Message
  alias Sycophant.Tool

  @tag recording_prefix: true
  test "generates text", %{model: model} do
    {:ok, response} =
      Sycophant.generate_text(
        model,
        [
          %Message{
            role: :system,
            content:
              "You are an echo bot. Reply with exactly the text the user sends, nothing else."
          },
          %Message{role: :user, content: "PING"}
        ],
        recording_opts([])
      )

    assert is_binary(response.text)
    assert response.text =~ ~r/PING/i
  end

  @tag recording_prefix: true
  test "streams text", %{model: model} do
    parent = self()

    callback = fn chunk ->
      if chunk.type == :text_delta, do: send(parent, {:chunk, chunk.data})
    end

    {:ok, response} =
      Sycophant.generate_text(
        model,
        [%Message{role: :user, content: "Say 'streaming works' and stop."}],
        recording_opts(stream: callback)
      )

    assert is_binary(response.text)
  end

  @tag recording_prefix: true
  test "executes a tool call round-trip", %{model: model} do
    weather_tool =
      %Tool{
        name: "get_weather",
        description: "Returns the weather for a city",
        parameters: %{
          type: "object",
          properties: %{city: %{type: "string"}},
          required: ["city"]
        },
        function: fn %{"city" => city} -> "It is sunny in #{city}." end
      }

    {:ok, response} =
      Sycophant.generate_text(
        model,
        [%Message{role: :user, content: "What's the weather in Tokyo?"}],
        recording_opts(tools: [weather_tool])
      )

    assert is_binary(response.text)
    assert response.text =~ ~r/sunny|tokyo/i
  end
end
