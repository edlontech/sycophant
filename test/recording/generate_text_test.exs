defmodule Sycophant.Recording.GenerateTextTest do
  @models Sycophant.RecordingCase.test_models()
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

  @tag recording_prefix: true
  test "continues a multi-turn conversation", %{model: model} do
    messages = [Message.user("My name is Sycophant. Remember it.")]

    {:ok, resp1} = Sycophant.generate_text(messages, recording_opts(model: model))
    assert is_binary(resp1.text)

    {:ok, resp2} =
      Sycophant.generate_text(resp1, Message.user("What is my name?"), recording_opts([]))

    assert is_binary(resp2.text)
    assert resp2.text =~ "Sycophant"

    history = Sycophant.Response.messages(resp2)
    assert length(history) == 4
    assert Enum.at(history, 0).role == :user
    assert Enum.at(history, 1).role == :assistant
    assert Enum.at(history, 2).role == :user
    assert Enum.at(history, 3).role == :assistant
  end
end
