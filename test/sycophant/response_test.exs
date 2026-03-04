defmodule Sycophant.ResponseTest do
  use ExUnit.Case, async: true

  alias Sycophant.{Context, Message, Params, Response, Tool, Usage}

  defp build_response(opts \\ []) do
    messages = Keyword.get(opts, :messages, [Message.user("hello")])

    %Response{
      text: Keyword.get(opts, :text, "Hi there!"),
      usage: %Usage{input_tokens: 10, output_tokens: 5},
      model: "openai:gpt-4o",
      raw: %{"id" => "chatcmpl-123"},
      context: %Context{
        messages: messages,
        model: "openai:gpt-4o"
      }
    }
  end

  describe "messages/1" do
    test "returns messages from context" do
      messages = [Message.user("hello"), Message.assistant("hi")]
      resp = build_response(messages: messages)

      assert Response.messages(resp) == messages
    end
  end

  describe "struct fields" do
    test "text response" do
      resp = build_response()
      assert resp.text == "Hi there!"
      assert resp.model == "openai:gpt-4o"
      assert resp.tool_calls == []
    end

    test "usage tracking" do
      resp = build_response()
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5
    end
  end

  describe "context carries config for continuation" do
    test "preserves model and params" do
      params = %Params{temperature: 0.7}
      tools = [%Tool{name: "search", description: "Search", parameters: Zoi.map(%{})}]

      resp = %Response{
        text: "ok",
        context: %Context{
          messages: [Message.user("hi")],
          model: "anthropic:claude-sonnet-4-20250514",
          params: params,
          tools: tools
        }
      }

      assert resp.context.model == "anthropic:claude-sonnet-4-20250514"
      assert resp.context.params == params
      assert resp.context.tools == tools
    end
  end
end
