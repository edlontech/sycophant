defmodule Sycophant.Recording.GenerateTextTest do
  @models (for model <- Application.compile_env(:sycophant, :test_models, []) do
             %{model: model, fixture_prefix: String.replace(model, ":", "/")}
           end)

  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "generates text", %{model: model} do
    messages = [Message.user("Say 'hello' and nothing else.")]

    assert {:ok, response} =
             Sycophant.generate_text(messages, recording_opts(model: model))

    assert is_binary(response.text)
    assert String.length(response.text) > 0
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  @tag recording_prefix: true
  test "generates text with system instructions", %{model: model} do
    messages = [
      Message.system("You are a calculator. Only respond with numbers."),
      Message.user("What is 2 + 2?")
    ]

    assert {:ok, response} =
             Sycophant.generate_text(messages, recording_opts(model: model))

    assert is_binary(response.text)
    assert response.text =~ "4"
  end
end
