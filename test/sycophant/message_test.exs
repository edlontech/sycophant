defmodule Sycophant.MessageTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.ToolCall

  describe "user/1" do
    test "creates a user message with string content" do
      msg = Message.user("hello")
      assert msg.role == :user
      assert msg.content == "hello"
      assert msg.metadata == %{}
    end

    test "creates a user message with content parts" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{url: "https://example.com/img.png", media_type: "image/png"}
      ]

      msg = Message.user(parts)
      assert msg.role == :user
      assert length(msg.content) == 2
    end
  end

  describe "assistant/1" do
    test "creates an assistant message" do
      msg = Message.assistant("hi there")
      assert msg.role == :assistant
      assert msg.content == "hi there"
    end
  end

  describe "system/1" do
    test "creates a system message" do
      msg = Message.system("you are helpful")
      assert msg.role == :system
      assert msg.content == "you are helpful"
    end
  end

  describe "tool_result/2" do
    test "creates a tool_result message linked to tool call" do
      tool_call = %ToolCall{id: "call_123", name: "get_weather", arguments: %{}}
      msg = Message.tool_result(tool_call, "22C and sunny")

      assert msg.role == :tool_result
      assert msg.content == "22C and sunny"
      assert msg.tool_call_id == "call_123"
    end
  end

  describe "metadata" do
    test "defaults to empty map" do
      assert Message.user("hi").metadata == %{}
    end

    test "can be set via struct update" do
      msg = %{Message.user("hi") | metadata: %{cache_control: "ephemeral"}}
      assert msg.metadata == %{cache_control: "ephemeral"}
    end
  end
end
