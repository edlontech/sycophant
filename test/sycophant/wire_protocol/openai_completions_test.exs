defmodule Sycophant.WireProtocol.OpenAICompletionsTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Params
  alias Sycophant.Request
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.WireProtocol.OpenAICompletions

  describe "encode_request/1 - messages" do
    test "encodes user message with string content" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    end

    test "encodes system message" do
      request = build_request([Message.system("be helpful")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert [%{"role" => "system", "content" => "be helpful"}] = payload["messages"]
    end

    test "encodes assistant message" do
      request = build_request([Message.assistant("hi there")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert [%{"role" => "assistant", "content" => "hi there"}] = payload["messages"]
    end

    test "encodes multimodal content with text and image URL" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{url: "https://example.com/img.png"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      [msg] = payload["messages"]
      assert [text_part, image_part] = msg["content"]
      assert text_part == %{"type" => "text", "text" => "describe this"}

      assert image_part == %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/img.png"}
             }
    end

    test "encodes image with base64 data as data URL" do
      parts = [%Content.Image{data: "abc123", media_type: "image/png"}]
      request = build_request([Message.user(parts)])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      [msg] = payload["messages"]
      [image_part] = msg["content"]
      assert image_part["image_url"]["url"] == "data:image/png;base64,abc123"
    end

    test "encodes tool_result as tool role with tool_call_id" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{}}
      msg = Message.tool_result(tc, "22C and sunny")
      request = build_request([msg])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      [encoded] = payload["messages"]
      assert encoded["role"] == "tool"
      assert encoded["tool_call_id"] == "call_1"
      assert encoded["content"] == "22C and sunny"
    end

    test "encodes assistant message with tool_calls" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      msg = %{Message.assistant(nil) | tool_calls: [tc]}
      request = build_request([msg])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      [encoded] = payload["messages"]
      assert encoded["role"] == "assistant"
      assert [tool_call] = encoded["tool_calls"]
      assert tool_call["id"] == "call_1"
      assert tool_call["type"] == "function"
      assert tool_call["function"]["name"] == "get_weather"
      assert tool_call["function"]["arguments"] == ~s({"city":"Paris"})
    end

    test "includes model in payload" do
      request = build_request([Message.user("hi")], model: "gpt-4o")
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["model"] == "gpt-4o"
    end

    test "encodes multi-turn conversation" do
      messages = [
        Message.system("be helpful"),
        Message.user("hello"),
        Message.assistant("hi there"),
        Message.user("how are you?")
      ]

      request = build_request(messages)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert length(payload["messages"]) == 4

      assert Enum.map(payload["messages"], & &1["role"]) == [
               "system",
               "user",
               "assistant",
               "user"
             ]
    end
  end

  describe "encode_request/1 - params" do
    test "translates canonical params to OpenAI names" do
      params = %Params{temperature: 0.7, max_tokens: 1000, top_p: 0.9}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["temperature"] == 0.7
      assert payload["max_completion_tokens"] == 1000
      assert payload["top_p"] == 0.9
    end

    test "omits nil params" do
      params = %Params{temperature: 0.5}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["temperature"] == 0.5
      refute Map.has_key?(payload, "max_completion_tokens")
      refute Map.has_key?(payload, "top_p")
    end

    test "drops unsupported params" do
      params = %Params{
        top_k: 40,
        cache_key: "abc",
        cache_retention: 3600,
        safety_identifier: "safe"
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      refute Map.has_key?(payload, "top_k")
      refute Map.has_key?(payload, "cache_key")
      refute Map.has_key?(payload, "cache_retention")
      refute Map.has_key?(payload, "safety_identifier")
    end

    test "translates reasoning to reasoning_effort as string" do
      params = %Params{reasoning: :medium}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["reasoning_effort"] == "medium"
    end

    test "translates stop sequences" do
      params = %Params{stop: ["END", "STOP"]}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["stop"] == ["END", "STOP"]
    end

    test "handles nil params struct" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      refute Map.has_key?(payload, "temperature")
    end
  end

  describe "encode_tools/1" do
    test "encodes tool list to OpenAI function format" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get current weather",
          parameters: Zoi.map(%{city: Zoi.string()})
        }
      ]

      assert {:ok, [encoded]} = OpenAICompletions.encode_tools(tools)
      assert encoded["type"] == "function"
      assert encoded["function"]["name"] == "get_weather"
      assert encoded["function"]["description"] == "Get current weather"
      assert encoded["function"]["strict"] == true
      assert encoded["function"]["parameters"]["type"] == "object"
      assert encoded["function"]["parameters"]["additionalProperties"] == false
      assert encoded["function"]["parameters"]["properties"]["city"]["type"] == "string"
    end

    test "encodes tools in request payload" do
      tools = [
        %Tool{
          name: "search",
          description: "Search the web",
          parameters: Zoi.map(%{query: Zoi.string()})
        }
      ]

      request = build_request([Message.user("hi")], tools: tools)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert [tool] = payload["tools"]
      assert tool["function"]["name"] == "search"
    end

    test "omits tools key when tools list is empty" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      refute Map.has_key?(payload, "tools")
    end

    test "returns error for invalid tool schema" do
      tools = [
        %Tool{name: "bad", description: "bad tool", parameters: Zoi.function()}
      ]

      assert {:error, %Sycophant.Error.Invalid.InvalidSchema{}} =
               OpenAICompletions.encode_tools(tools)
    end

    test "encode_request/1 propagates tool encoding error" do
      tools = [
        %Tool{name: "bad", description: "bad tool", parameters: Zoi.function()}
      ]

      request = build_request([Message.user("hi")], tools: tools)

      assert {:error, %Sycophant.Error.Invalid.InvalidSchema{}} =
               OpenAICompletions.encode_request(request)
    end
  end

  describe "encode_response_schema/1" do
    test "encodes Zoi schema to OpenAI response_format" do
      schema = Zoi.map(%{name: Zoi.string(), score: Zoi.float()})
      assert {:ok, format} = OpenAICompletions.encode_response_schema(schema)

      assert format["type"] == "json_schema"
      assert format["json_schema"]["name"] == "response"
      assert format["json_schema"]["strict"] == true
      assert format["json_schema"]["schema"]["type"] == "object"
      assert format["json_schema"]["schema"]["additionalProperties"] == false
    end

    test "includes response_format in request payload" do
      schema = Zoi.map(%{answer: Zoi.string()})
      request = build_request([Message.user("hi")], response_schema: schema)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["response_format"]["type"] == "json_schema"
    end

    test "omits response_format when no schema" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      refute Map.has_key?(payload, "response_format")
    end

    test "encode_request/1 propagates response schema encoding error" do
      request = build_request([Message.user("hi")], response_schema: Zoi.function())

      assert {:error, %Sycophant.Error.Invalid.InvalidSchema{}} =
               OpenAICompletions.encode_request(request)
    end
  end

  describe "decode_response/1 - text responses" do
    test "decodes a simple text response" do
      body = openai_response(content: "Hello there!")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.text == "Hello there!"
      assert resp.tool_calls == []
      assert resp.model == "gpt-4o-2024-08-06"
    end

    test "decodes usage tokens" do
      body = openai_response(content: "hi")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5
    end

    test "preserves raw response body" do
      body = openai_response(content: "hi")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.raw == body
    end

    test "handles nil content (tool call only response)" do
      body = openai_response(content: nil, tool_calls: [openai_tool_call()])
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.text == nil
      assert length(resp.tool_calls) == 1
    end

    test "returns placeholder context with empty messages" do
      body = openai_response(content: "hi")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.context.messages == []
    end
  end

  describe "decode_response/1 - tool calls" do
    test "decodes tool calls from response" do
      tc = openai_tool_call(id: "call_abc", name: "get_weather", arguments: ~s({"city":"Paris"}))
      body = openai_response(content: nil, tool_calls: [tc])
      assert {:ok, resp} = OpenAICompletions.decode_response(body)

      assert [tool_call] = resp.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"city" => "Paris"}
    end

    test "decodes multiple tool calls" do
      tcs = [
        openai_tool_call(id: "call_1", name: "search", arguments: ~s({"q":"elixir"})),
        openai_tool_call(id: "call_2", name: "weather", arguments: ~s({"city":"NYC"}))
      ]

      body = openai_response(content: nil, tool_calls: tcs)
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert length(resp.tool_calls) == 2
      assert Enum.map(resp.tool_calls, & &1.name) == ["search", "weather"]
    end

    test "returns error for unparseable tool call arguments" do
      tc = openai_tool_call(arguments: "not json {{{")
      body = openai_response(content: nil, tool_calls: [tc])
      assert {:error, %ResponseInvalid{errors: [msg]}} = OpenAICompletions.decode_response(body)
      assert msg =~ "Failed to decode"
    end

    test "returns error for malformed tool call structure" do
      body = openai_response(content: nil, tool_calls: [%{"bad" => "structure"}])
      assert {:error, %ResponseInvalid{}} = OpenAICompletions.decode_response(body)
    end
  end

  describe "decode_response/1 - error cases" do
    test "returns error for missing choices" do
      body = %{"id" => "chatcmpl-123", "model" => "gpt-4o"}
      assert {:error, %ResponseInvalid{}} = OpenAICompletions.decode_response(body)
    end

    test "returns error for empty choices" do
      body = %{"id" => "chatcmpl-123", "choices" => [], "model" => "gpt-4o"}
      assert {:error, %ResponseInvalid{}} = OpenAICompletions.decode_response(body)
    end

    test "handles missing usage gracefully" do
      body = openai_response(content: "hi") |> Map.delete("usage")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.usage == nil
    end
  end

  describe "decode_response/1 - round trip" do
    test "encode then decode preserves message content" do
      request = build_request([Message.user("what is 2+2?")])
      assert {:ok, _payload} = OpenAICompletions.encode_request(request)

      response_body = openai_response(content: "4")
      assert {:ok, resp} = OpenAICompletions.decode_response(response_body)
      assert resp.text == "4"
    end

    test "encode then decode preserves tool call data" do
      tc = %ToolCall{id: "call_1", name: "calc", arguments: %{"expr" => "2+2"}}
      msg = %{Message.assistant(nil) | tool_calls: [tc]}
      request = build_request([Message.user("calc"), msg])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      encoded_tc = hd(hd(tl(payload["messages"]))["tool_calls"])
      response_body = openai_response(content: nil, tool_calls: [encoded_tc])
      assert {:ok, resp} = OpenAICompletions.decode_response(response_body)

      assert [decoded_tc] = resp.tool_calls
      assert decoded_tc.id == "call_1"
      assert decoded_tc.name == "calc"
      assert decoded_tc.arguments == %{"expr" => "2+2"}
    end
  end

  defp build_request(messages, opts \\ []) do
    %Request{
      messages: messages,
      model: opts[:model] || "gpt-4o",
      params: opts[:params],
      tools: opts[:tools] || [],
      response_schema: opts[:response_schema]
    }
  end

  defp openai_response(opts) do
    content = Keyword.get(opts, :content)
    tool_calls = Keyword.get(opts, :tool_calls)

    message =
      then(
        %{"role" => "assistant", "content" => content},
        fn m ->
          if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m
        end
      )

    %{
      "id" => "chatcmpl-test123",
      "object" => "chat.completion",
      "model" => "gpt-4o-2024-08-06",
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp openai_tool_call(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "call_default"),
      "type" => "function",
      "function" => %{
        "name" => Keyword.get(opts, :name, "test_tool"),
        "arguments" => Keyword.get(opts, :arguments, ~s({"key":"value"}))
      }
    }
  end
end
