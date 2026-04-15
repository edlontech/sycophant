defmodule Sycophant.Recording.ReasoningTest do
  @models Sycophant.RecordingCase.test_models(require: :reasoning)
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "generates text with reasoning", %{model: model} do
    messages = [
      Message.user(
        "A farmer has 3 fields. The first field produces 2.5 times more wheat than the second. " <>
          "The third produces 40% less than the first. If the second field produces 120 tons, " <>
          "how many tons does the farmer produce in total? Show your reasoning."
      )
    ]

    assert {:ok, response} =
             Sycophant.generate_text(
               model,
               messages,
               recording_opts(reasoning: :low, reasoning_summary: :detailed)
             )

    assert is_binary(response.text)
    assert response.reasoning != nil
    assert response.reasoning.content != []
    assert Enum.any?(response.reasoning.content, &(&1.text != nil or &1.summary != nil))
  end
end
