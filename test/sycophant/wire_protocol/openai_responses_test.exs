defmodule Sycophant.WireProtocol.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.ContentFiltered
  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Request
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.WireProtocol.OpenAIResponses

  describe "encode_request/1 - system message extraction" do
    test "extracts single system message to instructions" do
      messages = [Message.system("be helpful"), Message.user("hello")]
      request = build_request(messages)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["instructions"] == "be helpful"
      assert length(payload["input"]) == 1
      assert hd(payload["input"])["role"] == "user"
    end

    test "concatenates multiple system messages" do
      messages = [
        Message.system("be helpful"),
        Message.system("be concise"),
        Message.user("hello")
      ]

      request = build_request(messages)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["instructions"] == "be helpful\nbe concise"
    end

    test "omits instructions when no system messages" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "instructions")
    end

    test "omits instructions when system messages are all empty strings" do
      messages = [Message.system(""), Message.system(""), Message.user("hello")]
      request = build_request(messages)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "instructions")
    end
  end

  describe "encode_request/1 - user messages" do
    test "encodes user message with string content" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert [%{"role" => "user", "content" => "hello"}] = payload["input"]
    end

    test "encodes multimodal content with input_text and input_image" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{url: "https://example.com/img.png"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      [msg] = payload["input"]
      assert [text_part, image_part] = msg["content"]
      assert text_part == %{"type" => "input_text", "text" => "describe this"}

      assert image_part == %{
               "type" => "input_image",
               "image_url" => "https://example.com/img.png"
             }
    end

    test "encodes image with base64 data as data URL" do
      parts = [%Content.Image{data: "abc123", media_type: "image/png"}]
      request = build_request([Message.user(parts)])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      [msg] = payload["input"]
      [image_part] = msg["content"]
      assert image_part["image_url"] == "data:image/png;base64,abc123"
    end
  end

  describe "encode_request/1 - assistant messages" do
    test "encodes assistant message as output item with type and status" do
      request = build_request([Message.assistant("hi there")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      [msg] = payload["input"]
      assert msg["type"] == "message"
      assert msg["role"] == "assistant"
      assert msg["status"] == "completed"
      assert [%{"type" => "output_text", "text" => "hi there"}] = msg["content"]
    end

    test "encodes assistant with nil content as output item with empty content" do
      request = build_request([Message.assistant(nil)])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      [msg] = payload["input"]
      assert msg["type"] == "message"
      assert msg["role"] == "assistant"
      assert msg["status"] == "completed"
      assert msg["content"] == []
    end

    test "encodes assistant with tool_calls as output item + function_call items" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      msg = %{Message.assistant("I'll check") | tool_calls: [tc]}
      request = build_request([msg])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert [assistant_item, fc_item] = payload["input"]
      assert assistant_item["type"] == "message"
      assert assistant_item["role"] == "assistant"
      assert assistant_item["status"] == "completed"
      assert [%{"type" => "output_text", "text" => "I'll check"}] = assistant_item["content"]

      assert fc_item["type"] == "function_call"
      assert fc_item["call_id"] == "call_1"
      assert fc_item["name"] == "get_weather"
      assert fc_item["arguments"] == ~s({"city":"Paris"})
    end
  end

  describe "encode_request/1 - tool results" do
    test "encodes tool_result as function_call_output" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{}}
      msg = Message.tool_result(tc, "22C and sunny")
      request = build_request([msg])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      [item] = payload["input"]
      assert item["type"] == "function_call_output"
      assert item["call_id"] == "call_1"
      assert item["output"] == "22C and sunny"
    end
  end

  describe "encode_request/1 - params" do
    test "translates canonical params" do
      params = %{temperature: 0.7, max_tokens: 1000, top_p: 0.9}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["temperature"] == 0.7
      assert payload["max_output_tokens"] == 1000
      assert payload["top_p"] == 0.9
    end

    test "omits nil params" do
      params = %{temperature: 0.5}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["temperature"] == 0.5
      refute Map.has_key?(payload, "max_output_tokens")
    end

    test "drops unsupported params" do
      params = %{
        top_k: 40,
        stop: ["END"],
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.5
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      refute Map.has_key?(payload, "top_k")
      refute Map.has_key?(payload, "stop")
      refute Map.has_key?(payload, "seed")
      refute Map.has_key?(payload, "frequency_penalty")
      refute Map.has_key?(payload, "presence_penalty")
    end

    test "nests reasoning params into reasoning object" do
      params = %{reasoning: :medium, reasoning_summary: :concise}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["reasoning"] == %{"effort" => "medium", "summary" => "concise"}
    end

    test "nests reasoning effort alone" do
      params = %{reasoning: :high}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["reasoning"] == %{"effort" => "high"}
    end

    test "omits reasoning object when both nil" do
      params = %{temperature: 0.5}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      refute Map.has_key?(payload, "reasoning")
    end

    test "translates cache_key to prompt_cache_key" do
      params = %{cache_key: "abc"}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["prompt_cache_key"] == "abc"
      refute Map.has_key?(payload, "cache_key")
    end

    test "passes safety_identifier through" do
      params = %{safety_identifier: "safe-123"}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["safety_identifier"] == "safe-123"
    end

    test "translates cache_retention to prompt_cache_retention" do
      params = %{cache_retention: "24h"}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["prompt_cache_retention"] == "24h"
      refute Map.has_key?(payload, "cache_retention")
    end

    test "handles nil params struct" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "temperature")
    end
  end

  describe "encode_request/1 - wire-specific params" do
    test "wire-specific params pass through via param_schema" do
      request =
        build_request([Message.user("hi")],
          params: %{cache_key: "abc", cache_retention: "24h", safety_identifier: "safe"}
        )

      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["prompt_cache_key"] == "abc"
      assert payload["prompt_cache_retention"] == "24h"
      assert payload["safety_identifier"] == "safe"
    end

    test "passes store boolean" do
      request = build_request([Message.user("hi")], params: %{store: false})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["store"] == false
    end

    test "passes truncation as string" do
      request = build_request([Message.user("hi")], params: %{truncation: :auto})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["truncation"] == "auto"
    end

    test "passes include array" do
      includes = ["reasoning.encrypted_content", "message.output_text.logprobs"]
      request = build_request([Message.user("hi")], params: %{include: includes})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["include"] == includes
    end

    test "passes top_logprobs" do
      request = build_request([Message.user("hi")], params: %{top_logprobs: 5})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["top_logprobs"] == 5
    end

    test "passes max_tool_calls" do
      request = build_request([Message.user("hi")], params: %{max_tool_calls: 3})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["max_tool_calls"] == 3
    end

    test "passes metadata map" do
      meta = %{"run_id" => "abc123"}
      request = build_request([Message.user("hi")], params: %{metadata: meta})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["metadata"] == meta
    end

    test "passes stream_options" do
      opts = %{"include_obfuscation" => false}
      request = build_request([Message.user("hi")], params: %{stream_options: opts})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["stream_options"] == opts
    end

    test "passes context_management" do
      config = [%{"type" => "compaction", "compact_threshold" => 10_000}]
      request = build_request([Message.user("hi")], params: %{context_management: config})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["context_management"] == config
    end

    test "nests verbosity under text object" do
      request = build_request([Message.user("hi")], params: %{verbosity: :low})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["text"] == %{"verbosity" => "low"}
    end

    test "includes verbosity alongside format in text object" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => ["answer"]
      }

      request =
        build_request([Message.user("hi")],
          response_schema: schema,
          params: %{verbosity: :medium}
        )

      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["text"]["verbosity"] == "medium"
      assert payload["text"]["format"]["type"] == "json_schema"
    end

    test "omits new params when not set" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      refute Map.has_key?(payload, "store")
      refute Map.has_key?(payload, "truncation")
      refute Map.has_key?(payload, "include")
      refute Map.has_key?(payload, "top_logprobs")
      refute Map.has_key?(payload, "max_tool_calls")
      refute Map.has_key?(payload, "metadata")
      refute Map.has_key?(payload, "stream_options")
      refute Map.has_key?(payload, "context_management")
      refute Map.has_key?(payload, "text")
    end
  end

  describe "encode_request/1 - multi-turn" do
    test "encodes multi-turn conversation" do
      tc = %ToolCall{id: "call_1", name: "search", arguments: %{"q" => "elixir"}}

      messages = [
        Message.system("be helpful"),
        Message.user("search for elixir"),
        %{Message.assistant("I'll search") | tool_calls: [tc]},
        Message.tool_result(tc, "Elixir is a language"),
        Message.user("tell me more")
      ]

      request = build_request(messages)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["instructions"] == "be helpful"
      assert length(payload["input"]) == 5

      [user1, assistant, fc, fco, user2] = payload["input"]
      assert user1["role"] == "user"
      assert assistant["type"] == "message"
      assert assistant["role"] == "assistant"
      assert assistant["status"] == "completed"
      assert fc["type"] == "function_call"
      assert fco["type"] == "function_call_output"
      assert user2["role"] == "user"
    end

    test "includes model in payload" do
      request = build_request([Message.user("hi")], model: "gpt-4o")
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["model"] == "gpt-4o"
    end
  end

  describe "encode_tools/1" do
    test "encodes tool with flat format" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get current weather",
          parameters: %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      ]

      assert {:ok, [encoded]} = OpenAIResponses.encode_tools(tools)
      assert encoded["type"] == "function"
      assert encoded["name"] == "get_weather"
      assert encoded["description"] == "Get current weather"
      assert encoded["strict"] == true
      assert encoded["parameters"]["type"] == "object"
      assert encoded["parameters"]["additionalProperties"] == false
      assert encoded["parameters"]["properties"]["city"]["type"] == "string"
    end

    test "does not nest in function wrapper" do
      tools = [
        %Tool{
          name: "search",
          description: "Search",
          parameters: %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          }
        }
      ]

      assert {:ok, [encoded]} = OpenAIResponses.encode_tools(tools)
      refute Map.has_key?(encoded, "function")
    end

    test "encodes tools in request payload" do
      tools = [
        %Tool{
          name: "search",
          description: "Search the web",
          parameters: %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          }
        }
      ]

      request = build_request([Message.user("hi")], tools: tools)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert [tool] = payload["tools"]
      assert tool["name"] == "search"
    end

    test "omits tools key when tools list is empty" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "tools")
    end
  end

  describe "encode_response_schema/1" do
    test "encodes JSON Schema to Responses API text.format" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "score" => %{"type" => "number"}
        },
        "required" => ["name", "score"]
      }

      assert {:ok, format} = OpenAIResponses.encode_response_schema(schema)

      assert format["type"] == "json_schema"
      assert format["name"] == "response"
      assert format["strict"] == true
      assert format["schema"]["type"] == "object"
      assert format["schema"]["additionalProperties"] == false
    end

    test "includes text.format in request payload" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => ["answer"]
      }

      request = build_request([Message.user("hi")], response_schema: schema)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["text"]["format"]["type"] == "json_schema"
    end

    test "omits text key when no schema" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "text")
    end
  end

  describe "decode_response/1 - text responses" do
    test "decodes a simple text response" do
      body = responses_api_response(text: "Hello there!")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.text == "Hello there!"
      assert resp.tool_calls == []
      assert resp.model == "gpt-4o-2024-08-06"
      assert resp.finish_reason == :stop
    end

    test "decodes usage tokens" do
      body = responses_api_response(text: "hi")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 20
    end

    test "preserves raw response body" do
      body = responses_api_response(text: "hi")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.raw == body
    end

    test "returns nil text for tool-call-only response" do
      body =
        responses_api_response(
          text: nil,
          tool_calls: [responses_function_call()]
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.text == nil
      assert length(resp.tool_calls) == 1
    end

    test "returns placeholder context with empty messages" do
      body = responses_api_response(text: "hi")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.context.messages == []
    end
  end

  describe "decode_response/1 - tool calls" do
    test "decodes function_call items" do
      fc =
        responses_function_call(
          call_id: "call_abc",
          name: "get_weather",
          arguments: ~s({"city":"Paris"})
        )

      body = responses_api_response(text: nil, tool_calls: [fc])
      assert {:ok, resp} = OpenAIResponses.decode_response(body)

      assert [tool_call] = resp.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"city" => "Paris"}
      assert resp.finish_reason == :stop
    end

    test "decodes multiple function_call items" do
      fcs = [
        responses_function_call(call_id: "c1", name: "search", arguments: ~s({"q":"elixir"})),
        responses_function_call(call_id: "c2", name: "weather", arguments: ~s({"city":"NYC"}))
      ]

      body = responses_api_response(text: nil, tool_calls: fcs)
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert length(resp.tool_calls) == 2
      assert Enum.map(resp.tool_calls, & &1.name) == ["search", "weather"]
    end

    test "returns error for unparseable tool call arguments" do
      fc = responses_function_call(arguments: "not json {{{")
      body = responses_api_response(text: nil, tool_calls: [fc])
      assert {:error, %ResponseInvalid{errors: [msg]}} = OpenAIResponses.decode_response(body)
      assert msg =~ "Failed to decode"
    end

    test "returns error for malformed function_call structure" do
      body =
        responses_api_response(
          text: nil,
          tool_calls: [%{"type" => "function_call", "bad" => "structure"}]
        )

      assert {:error, %ResponseInvalid{}} = OpenAIResponses.decode_response(body)
    end
  end

  describe "decode_response/1 - reasoning" do
    test "decodes reasoning with summary" do
      body =
        responses_api_response(
          text: "The answer is 42",
          reasoning: responses_reasoning(summary: "Thinking about the meaning of life")
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.text == "The answer is 42"
      assert [%{summary: "Thinking about the meaning of life"}] = resp.reasoning.content
    end

    test "returns nil reasoning when no reasoning items" do
      body = responses_api_response(text: "hello")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.reasoning == nil
    end

    test "decodes reasoning with encrypted_content" do
      body =
        responses_api_response(
          text: "answer",
          reasoning: %{
            "type" => "reasoning",
            "id" => "rs_test",
            "encrypted_content" => "encrypted_blob"
          }
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.reasoning.encrypted_content == "encrypted_blob"
    end
  end

  describe "decode_response/1 - refusal" do
    test "returns ContentFiltered error for refusal" do
      body = responses_api_response(refusal: "I cannot help with that")
      assert {:error, %ContentFiltered{reason: reason}} = OpenAIResponses.decode_response(body)
      assert reason == "I cannot help with that"
    end
  end

  describe "decode_response/1 - error cases" do
    test "returns error for missing output" do
      body = %{"id" => "resp_123", "model" => "gpt-4o"}
      assert {:error, %ResponseInvalid{}} = OpenAIResponses.decode_response(body)
    end

    test "returns ServerError for failed status with server_error code" do
      body = %{
        "id" => "resp_123",
        "status" => "failed",
        "error" => %{"code" => "server_error", "message" => "Something went wrong"}
      }

      assert {:error, %ServerError{body: body_msg}} = OpenAIResponses.decode_response(body)
      assert body_msg == "Something went wrong"
    end

    test "returns RateLimited for failed status with rate_limit_exceeded code" do
      body = %{
        "id" => "resp_123",
        "status" => "failed",
        "error" => %{"code" => "rate_limit_exceeded", "message" => "Too many requests"}
      }

      assert {:error, %RateLimited{}} = OpenAIResponses.decode_response(body)
    end

    test "returns error for incomplete status" do
      body = %{
        "id" => "resp_123",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "output" => []
      }

      assert {:error, %ResponseInvalid{errors: [msg]}} = OpenAIResponses.decode_response(body)
      assert msg =~ "incomplete"
      assert msg =~ "max_output_tokens"
    end

    test "handles missing usage gracefully" do
      body = responses_api_response(text: "hi") |> Map.delete("usage")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.usage == nil
    end

    test "skips unknown output item types" do
      body = responses_api_response(text: "hello")

      body =
        Map.update!(body, "output", fn items ->
          [%{"type" => "web_search_call", "id" => "ws_1", "status" => "completed"} | items]
        end)

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.text == "hello"
    end
  end

  describe "decode_response/1 - mixed output items" do
    test "decodes response with reasoning + text + tool calls" do
      fc = responses_function_call(call_id: "c1", name: "calc", arguments: ~s({"x":1}))
      reasoning = responses_reasoning(summary: "Let me think")

      body =
        responses_api_response(
          text: "Here's what I found",
          tool_calls: [fc],
          reasoning: reasoning
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.text == "Here's what I found"
      assert length(resp.tool_calls) == 1
      assert [%{summary: "Let me think"}] = resp.reasoning.content
    end
  end

  describe "decode_response/1 - metadata" do
    test "populates metadata with response id" do
      body = responses_api_response(text: "hi")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.metadata == %{openai_responses: %{id: "resp_test123"}}
    end

    test "returns empty metadata when id is missing" do
      body = responses_api_response(text: "hi") |> Map.delete("id")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.metadata == %{}
    end
  end

  describe "encode_request/1 - previous_response_id" do
    test "passes previous_response_id from params" do
      params = %{previous_response_id: "resp_abc123"}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["previous_response_id"] == "resp_abc123"
    end

    test "omits previous_response_id when not set" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "previous_response_id")
    end
  end

  describe "round trip" do
    test "encode then decode preserves message content" do
      request = build_request([Message.user("what is 2+2?")])
      assert {:ok, _payload} = OpenAIResponses.encode_request(request)

      response_body = responses_api_response(text: "4")
      assert {:ok, resp} = OpenAIResponses.decode_response(response_body)
      assert resp.text == "4"
    end

    test "encode then decode preserves tool call data" do
      tc = %ToolCall{id: "call_1", name: "calc", arguments: %{"expr" => "2+2"}}
      msg = %{Message.assistant(nil) | tool_calls: [tc]}
      request = build_request([Message.user("calc"), msg])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      fc_item = Enum.find(payload["input"], &(&1["type"] == "function_call"))

      response_body =
        responses_api_response(
          text: nil,
          tool_calls: [
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => fc_item["call_id"],
              "name" => fc_item["name"],
              "arguments" => fc_item["arguments"],
              "status" => "completed"
            }
          ]
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(response_body)
      assert [decoded_tc] = resp.tool_calls
      assert decoded_tc.id == "call_1"
      assert decoded_tc.name == "calc"
      assert decoded_tc.arguments == %{"expr" => "2+2"}
    end
  end

  describe "map_finish_reason/1" do
    test "maps provider-specific values to canonical atoms" do
      for {status, expected_atom} <- [
            {"completed", :stop},
            {"failed", :error},
            {"incomplete", :incomplete}
          ] do
        body = %{responses_api_response(text: "hi") | "status" => status}
        assert {:ok, resp} = OpenAIResponses.decode_response(body)
        assert resp.finish_reason == expected_atom
      end
    end

    test "maps nil to nil" do
      body = %{responses_api_response(text: "hi") | "status" => nil}
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.finish_reason == nil
    end

    test "maps unknown values to :unknown" do
      body = %{responses_api_response(text: "hi") | "status" => "something_new"}
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.finish_reason == :unknown
    end
  end

  describe "param_schema/0" do
    test "validates supported params" do
      schema = OpenAIResponses.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7})
      assert result.temperature == 0.7
    end

    test "strips unsupported params" do
      schema = OpenAIResponses.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7, unknown_param: true})
      refute Map.has_key?(result, :unknown_param)
    end

    test "rejects invalid values" do
      schema = OpenAIResponses.param_schema()
      assert {:error, _} = Zoi.parse(schema, %{temperature: 5.0})
    end

    test "accepts wire-specific extras" do
      schema = OpenAIResponses.param_schema()

      assert {:ok, result} =
               Zoi.parse(schema, %{
                 cache_key: "abc",
                 cache_retention: "24h",
                 safety_identifier: "safe"
               })

      assert result.cache_key == "abc"
      assert result.cache_retention == "24h"
      assert result.safety_identifier == "safe"
    end
  end

  # --- Helpers ---

  defp build_request(messages, opts \\ []) do
    %Request{
      messages: messages,
      model: opts[:model] || "gpt-4o",
      params: opts[:params] || %{},
      tools: opts[:tools] || [],
      response_schema: opts[:response_schema],
      stream: opts[:stream]
    }
  end

  defp responses_api_response(opts) do
    text = Keyword.get(opts, :text)
    tool_calls = Keyword.get(opts, :tool_calls, [])
    reasoning = Keyword.get(opts, :reasoning)
    refusal = Keyword.get(opts, :refusal)

    output = []

    output =
      if reasoning do
        [reasoning | output]
      else
        output
      end

    output =
      if text do
        msg_item = %{
          "type" => "message",
          "id" => "msg_test",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
        }

        output ++ [msg_item]
      else
        if refusal do
          msg_item = %{
            "type" => "message",
            "id" => "msg_test",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "refusal", "refusal" => refusal}]
          }

          output ++ [msg_item]
        else
          output
        end
      end

    output = output ++ tool_calls

    %{
      "id" => "resp_test123",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-4o-2024-08-06",
      "output" => output,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}
    }
  end

  defp responses_function_call(opts \\ []) do
    %{
      "type" => "function_call",
      "id" => "fc_default",
      "call_id" => Keyword.get(opts, :call_id, "call_default"),
      "name" => Keyword.get(opts, :name, "test_tool"),
      "arguments" => Keyword.get(opts, :arguments, ~s({"key":"value"})),
      "status" => "completed"
    }
  end

  defp responses_reasoning(opts) do
    summary_text = Keyword.get(opts, :summary, "Thinking...")

    %{
      "type" => "reasoning",
      "id" => "rs_test",
      "summary" => [%{"type" => "summary_text", "text" => summary_text}]
    }
  end

  describe "encode_request/1 - streaming" do
    test "adds stream: true when request.stream is set" do
      callback = fn _chunk -> :ok end
      request = build_request([Message.user("hello")], stream: callback)
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["stream"] == true
    end

    test "does not add stream or stream_options when stream is nil" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      refute Map.has_key?(payload, "stream")
      refute Map.has_key?(payload, "stream_options")
    end
  end

  describe "init_stream/0" do
    test "returns nil" do
      assert OpenAIResponses.init_stream() == nil
    end
  end

  describe "decode_stream_chunk/2" do
    test "decodes text delta event" do
      event = %{
        event: "response.output_text.delta",
        data: %{
          "type" => "response.output_text.delta",
          "delta" => "Hello",
          "item_id" => "item_1",
          "output_index" => 0,
          "content_index" => 0
        }
      }

      assert {:ok, nil, [%StreamChunk{type: :text_delta, data: "Hello"}]} =
               OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes function call arguments delta event" do
      event = %{
        event: "response.function_call_arguments.delta",
        data: %{
          "delta" => "{\"city\":",
          "item_id" => "fc_1",
          "output_index" => 0
        }
      }

      assert {:ok, nil,
              [
                %StreamChunk{
                  type: :tool_call_delta,
                  data: %{id: "fc_1", name: nil, arguments_delta: "{\"city\":"},
                  index: 0
                }
              ]} = OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes reasoning summary text delta event" do
      event = %{
        event: "response.reasoning_summary_text.delta",
        data: %{
          "delta" => "Let me think...",
          "item_id" => "rs_1",
          "output_index" => 0
        }
      }

      assert {:ok, nil, [%StreamChunk{type: :reasoning_delta, data: "Let me think..."}]} =
               OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "response.completed delegates to decode_response and returns {:done, Response}" do
      completed_response = responses_api_response(text: "Final answer")

      event = %{
        event: "response.completed",
        data: %{"response" => completed_response}
      }

      assert {:done, response} = OpenAIResponses.decode_stream_chunk(nil, event)
      assert response.text == "Final answer"
      assert response.model == "gpt-4o-2024-08-06"
      assert response.finish_reason == :stop
    end

    test "unknown events return empty chunks" do
      event = %{
        event: "response.created",
        data: %{"type" => "response.created"}
      }

      assert {:ok, nil, []} = OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes text delta from data type when event key is missing" do
      event = %{
        data: %{
          "type" => "response.output_text.delta",
          "delta" => "Hello",
          "item_id" => "item_1",
          "output_index" => 0,
          "content_index" => 0
        }
      }

      assert {:ok, nil, [%StreamChunk{type: :text_delta, data: "Hello"}]} =
               OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes function call delta from data type when event key is missing" do
      event = %{
        data: %{
          "type" => "response.function_call_arguments.delta",
          "delta" => "{\"city\":",
          "item_id" => "fc_1",
          "output_index" => 0
        }
      }

      assert {:ok, nil,
              [
                %StreamChunk{
                  type: :tool_call_delta,
                  data: %{id: "fc_1", name: nil, arguments_delta: "{\"city\":"},
                  index: 0
                }
              ]} = OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes reasoning delta from data type when event key is missing" do
      event = %{
        data: %{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "Let me think...",
          "item_id" => "rs_1",
          "output_index" => 0
        }
      }

      assert {:ok, nil, [%StreamChunk{type: :reasoning_delta, data: "Let me think..."}]} =
               OpenAIResponses.decode_stream_chunk(nil, event)
    end

    test "decodes response.completed from data type when event key is missing" do
      completed_response = responses_api_response(text: "Final answer")

      event = %{
        data: %{
          "type" => "response.completed",
          "response" => completed_response
        }
      }

      assert {:done, response} = OpenAIResponses.decode_stream_chunk(nil, event)
      assert response.text == "Final answer"
    end
  end

  describe "encode_request/1 - tool_choice" do
    test "encodes :auto as \"auto\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :auto})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["tool_choice"] == "auto"
    end

    test "encodes :none as \"none\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :none})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["tool_choice"] == "none"
    end

    test "encodes :any as \"required\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :any})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      assert payload["tool_choice"] == "required"
    end

    test "encodes {:tool, name} as allowed_tools object" do
      request =
        build_request([Message.user("hi")], params: %{tool_choice: {:tool, "get_weather"}})

      assert {:ok, payload} = OpenAIResponses.encode_request(request)

      assert payload["tool_choice"] == %{
               "type" => "allowed_tools",
               "mode" => "required",
               "tools" => [%{"type" => "function", "name" => "get_weather"}]
             }
    end

    test "omits tool_choice when nil" do
      request = build_request([Message.user("hi")], params: %{tool_choice: nil})
      assert {:ok, payload} = OpenAIResponses.encode_request(request)
      refute Map.has_key?(payload, "tool_choice")
    end
  end

  describe "decode_response/1 - cache usage" do
    test "decodes cached_tokens from prompt_tokens_details" do
      body =
        responses_api_response(text: "hi")
        |> put_in(
          ["usage", "prompt_tokens_details"],
          %{"cached_tokens" => 50}
        )

      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.usage.cache_read_input_tokens == 50
      assert resp.usage.cache_creation_input_tokens == nil
    end

    test "sets cache fields to nil when prompt_tokens_details is absent" do
      body = responses_api_response(text: "hi")
      assert {:ok, resp} = OpenAIResponses.decode_response(body)
      assert resp.usage.cache_read_input_tokens == nil
      assert resp.usage.cache_creation_input_tokens == nil
    end
  end

  describe "request_path/1" do
    test "returns /responses" do
      assert OpenAIResponses.request_path(%Sycophant.Request{messages: []}) == "/responses"
    end
  end
end
