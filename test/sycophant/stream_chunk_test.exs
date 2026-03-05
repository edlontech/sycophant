defmodule Sycophant.StreamChunkTest do
  use ExUnit.Case, async: true

  alias Sycophant.StreamChunk

  describe "struct creation" do
    test "creates text_delta chunk" do
      chunk = %StreamChunk{type: :text_delta, data: "Hello"}
      assert chunk.type == :text_delta
      assert chunk.data == "Hello"
      assert chunk.index == nil
    end

    test "creates tool_call_delta chunk with index" do
      chunk = %StreamChunk{
        type: :tool_call_delta,
        data: %{id: "call_1", name: "weather", arguments_delta: "{\"ci"},
        index: 0
      }

      assert chunk.type == :tool_call_delta
      assert chunk.index == 0
    end

    test "creates reasoning_delta chunk" do
      chunk = %StreamChunk{type: :reasoning_delta, data: "thinking..."}
      assert chunk.type == :reasoning_delta
    end

    test "creates usage chunk" do
      chunk = %StreamChunk{
        type: :usage,
        data: %Sycophant.Usage{input_tokens: 10, output_tokens: 5}
      }

      assert chunk.type == :usage
      assert chunk.data.input_tokens == 10
    end

    test "enforces type field" do
      assert_raise ArgumentError, fn ->
        struct!(StreamChunk, data: "Hello")
      end
    end
  end
end
