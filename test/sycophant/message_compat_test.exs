defmodule Sycophant.MessageCompatTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message
  alias Sycophant.Message.Content.RedactedThinking
  alias Sycophant.Message.Content.Text
  alias Sycophant.Message.Content.Thinking
  alias Sycophant.MessageCompat
  alias Sycophant.ToolCall

  @anthropic {:anthropic, :anthropic_messages}
  @openai {:openai, :openai_responses}

  defp anthropic_history do
    tool_call = %ToolCall{id: "toolu_01abc", name: "get_weather", arguments: %{"city" => "Paris"}}

    [
      Message.user("Weather in Paris?"),
      %Message{
        role: :assistant,
        content: [
          %Thinking{text: "Need the tool.", signature: "sig"},
          %RedactedThinking{data: "opaque"},
          %Text{text: "Checking."}
        ],
        tool_calls: [tool_call],
        provider: :anthropic,
        wire_protocol: :anthropic_messages
      },
      Message.tool_result(tool_call, "18C")
    ]
  end

  defp reasoning_parts(messages) do
    for %Message{content: parts} when is_list(parts) <- messages,
        %mod{} <- parts,
        mod in [Thinking, RedactedThinking],
        do: mod
  end

  describe "reasoning from other origins" do
    test "same origin is unchanged" do
      history = anthropic_history()
      assert MessageCompat.adapt(history, @anthropic) == history
    end

    test "foreign reasoning is stripped" do
      adapted = MessageCompat.adapt(anthropic_history(), @openai)
      assistant = Enum.at(adapted, 1)

      assert reasoning_parts(adapted) == []
      assert assistant.content == [%Text{text: "Checking."}]
      assert [%ToolCall{id: "toolu_01abc"}] = assistant.tool_calls
    end

    test "foreign thought_signature dropped" do
      gemini_turn = %Message{
        role: :assistant,
        tool_calls: [
          %ToolCall{id: "c1", name: "f", metadata: %{thought_signature: "s", other: 1}}
        ],
        provider: :google,
        wire_protocol: :google_gemini
      }

      [adapted] = MessageCompat.adapt([gemini_turn], @anthropic)
      assert [%ToolCall{metadata: %{other: 1} = metadata}] = adapted.tool_calls
      refute Map.has_key?(metadata, :thought_signature)
    end

    test "reasoning-only foreign turn is removed" do
      reasoning_only = %Message{
        role: :assistant,
        content: [%Thinking{text: "hmm", signature: "sig"}],
        provider: :anthropic,
        wire_protocol: :anthropic_messages
      }

      assert MessageCompat.adapt([Message.user("hi"), reasoning_only], @openai) ==
               [Message.user("hi")]
    end

    test "empty part list becomes nil" do
      turn = %Message{
        role: :assistant,
        content: [%Thinking{text: "hmm", signature: "sig"}],
        tool_calls: [%ToolCall{id: "c1", name: "f"}],
        provider: :anthropic,
        wire_protocol: :anthropic_messages
      }

      [adapted] = MessageCompat.adapt([turn], @openai)
      assert adapted.content == nil
      assert [%ToolCall{id: "c1"}] = adapted.tool_calls
    end

    test "untagged turns pass through" do
      untagged = %Message{role: :assistant, content: [%Thinking{text: "t", signature: "sig"}]}
      assert MessageCompat.adapt([untagged], @openai) == [untagged]
    end
  end

  defp call_and_result(id) do
    tool_call = %ToolCall{id: id, name: "get_weather"}
    [%Message{role: :assistant, tool_calls: [tool_call]}, Message.tool_result(tool_call, "ok")]
  end

  defp ids(messages) do
    Enum.flat_map(messages, fn
      %Message{role: :assistant, tool_calls: [_ | _] = tcs} -> Enum.map(tcs, &{:call, &1.id})
      %Message{role: :tool_result, tool_call_id: id} -> [{:result, id}]
      _ -> []
    end)
  end

  describe "tool call ids" do
    test "invalid id characters replaced" do
      adapted = MessageCompat.adapt(call_and_result("functions.get_weather:0"), @anthropic)

      assert ids(adapted) == [
               {:call, "functions_get_weather_0"},
               {:result, "functions_get_weather_0"}
             ]
    end

    test "long id truncated to 64" do
      long = String.duplicate("a", 100)
      short = String.duplicate("a", 64)

      assert ids(MessageCompat.adapt(call_and_result(long), @anthropic)) ==
               [{:call, short}, {:result, short}]
    end

    test "repeated ids across turns pair with most recent call" do
      history = call_and_result("gemini_call_0") ++ call_and_result("gemini_call_0")

      assert ids(MessageCompat.adapt(history, @anthropic)) == [
               {:call, "gemini_call_0"},
               {:result, "gemini_call_0"},
               {:call, "gemini_call_0_1"},
               {:result, "gemini_call_0_1"}
             ]
    end

    test "orphan tool result sanitized" do
      orphan = %Message{role: :tool_result, content: "ok", tool_call_id: "a.b"}
      assert [%Message{tool_call_id: "a_b"}] = MessageCompat.adapt([orphan], @anthropic)
    end

    test "empty id becomes call" do
      assert ids(MessageCompat.adapt(call_and_result(""), @anthropic)) ==
               [{:call, "call"}, {:result, "call"}]
    end

    test "adapt is deterministic and idempotent" do
      history =
        anthropic_history() ++
          call_and_result("gemini_call_0") ++
          call_and_result("gemini_call_0") ++ call_and_result("bad.id")

      once = MessageCompat.adapt(history, @openai)

      assert MessageCompat.adapt(history, @openai) == once
      assert MessageCompat.adapt(once, @openai) == once
    end
  end
end
