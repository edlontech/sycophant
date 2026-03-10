defmodule Sycophant.Integration.GenerateTextTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message

  @moduletag :integration

  test "generates text with OpenAI gpt-4o-mini" do
    messages = [Message.user("Say 'hello' and nothing else.")]

    assert {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
    assert is_binary(response.text)
    assert response.text =~ ~r/hello/i
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  test "generates text with system message" do
    messages = [
      Message.system("You are a calculator. Only respond with numbers."),
      Message.user("What is 2 + 2?")
    ]

    assert {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
    assert is_binary(response.text)
    assert response.text =~ "4"
  end

  test "respects temperature parameter" do
    messages = [Message.user("What is the capital of France? One word only.")]

    assert {:ok, response} =
             Sycophant.generate_text("openai:gpt-4o-mini", messages, temperature: 0.0)

    assert is_binary(response.text)
    assert response.text =~ "Paris"
  end

  test "returns error for invalid credentials" do
    messages = [Message.user("Hello")]

    assert {:error, _} =
             Sycophant.generate_text("openai:gpt-4o-mini", messages,
               credentials: %{api_key: "sk-invalid"}
             )
  end
end
