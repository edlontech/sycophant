defmodule Sycophant.ResponseTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Response
  alias Sycophant.Tool
  alias Sycophant.Usage

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

  defp base_response_map(extra) do
    Map.merge(
      %{
        "__type__" => "Response",
        "text" => "hello",
        "context" => %{
          "__type__" => "Context",
          "messages" => [
            %{"__type__" => "Message", "role" => "user", "content" => "hi"}
          ]
        }
      },
      extra
    )
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

    test "finish_reason defaults to nil" do
      resp = build_response()
      assert resp.finish_reason == nil
    end

    test "finish_reason can be set" do
      resp = %{build_response() | finish_reason: :stop}
      assert resp.finish_reason == :stop
    end
  end

  describe "finish_reason decoding in from_map/1" do
    test "decodes valid finish_reason string to atom" do
      for reason <-
            ~w(stop tool_use max_tokens content_filter recitation error incomplete unknown) do
        data = base_response_map(%{"finish_reason" => reason})
        resp = Response.from_map(data)
        assert resp.finish_reason == String.to_existing_atom(reason)
      end
    end

    test "decodes nil finish_reason to nil" do
      data = base_response_map(%{})
      resp = Response.from_map(data)
      assert resp.finish_reason == nil
    end

    test "decodes unrecognized finish_reason string to :unknown" do
      data = base_response_map(%{"finish_reason" => "something_weird"})
      resp = Response.from_map(data)
      assert resp.finish_reason == :unknown
    end
  end

  describe "context carries config for continuation" do
    test "preserves model and params" do
      params = %{temperature: 0.7}
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
