defmodule Sycophant.Recording.EagerInputStreamingTest do
  use Sycophant.RecordingCase, async: true

  alias Sycophant.Message
  alias Sycophant.StreamChunk
  alias Sycophant.Tool

  @model "anthropic:claude-haiku-4-5-20251001"

  @tag recording: "anthropic/claude-haiku-4-5-20251001/streams_eager_tool_input"
  test "streams a large tool argument with eager_input_streaming" do
    test_pid = self()

    tool = %Tool{
      name: "write_file",
      description: "Write text content to a file.",
      parameters: Zoi.map(%{path: Zoi.string(), content: Zoi.string()}),
      eager_input_streaming: true,
      function: fn %{path: path, content: content} ->
        send(test_pid, {:wrote, path, content})
        "Wrote #{byte_size(content)} bytes to #{path}"
      end
    }

    messages = [
      Message.user(
        "Write a 20 line poem about the sea and save it to poem.txt with the write_file tool. " <>
          "After writing, reply with just 'done'."
      )
    ]

    callback = fn chunk -> send(test_pid, {:chunk, chunk}) end

    assert {:ok, response} =
             Sycophant.generate_text(
               @model,
               messages,
               recording_opts(tools: [tool], stream: callback)
             )

    assert response.tool_calls == []
    assert_received {:wrote, "poem.txt", content}
    assert String.length(content) > 200

    deltas = collect_tool_call_deltas()
    assert length(deltas) > 1, "expected tool input to arrive in several deltas"
  end

  defp collect_tool_call_deltas(acc \\ []) do
    receive do
      {:chunk, %StreamChunk{type: :tool_call_delta} = chunk} ->
        collect_tool_call_deltas([chunk | acc])

      {:chunk, _} ->
        collect_tool_call_deltas(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
