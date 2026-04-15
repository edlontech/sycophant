defmodule Sycophant.WireProtocol.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.WireProtocol.AnthropicMessages

  describe "request_path/1" do
    test "returns /v1/messages" do
      assert AnthropicMessages.request_path(%Sycophant.Request{messages: []}) == "/v1/messages"
    end
  end

  describe "encode_request/1 - system messages" do
    test "extracts system messages into top-level system field" do
      request = build_request([Message.system("be helpful"), Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert payload["system"] == "be helpful"
      assert [%{"role" => "user"}] = payload["messages"]
    end

    test "concatenates multiple system messages" do
      request =
        build_request([
          Message.system("be helpful"),
          Message.system("be concise"),
          Message.user("hi")
        ])

      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["system"] == "be helpful\nbe concise"
    end

    test "omits system field when no system messages" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      refute Map.has_key?(payload, "system")
    end

    test "extracts text from system message content parts" do
      request =
        build_request([
          Message.system([
            %Content.Text{text: "be helpful"},
            %Content.Text{text: "be concise"}
          ]),
          Message.user("hi")
        ])

      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["system"] == "be helpful\nbe concise"
    end
  end

  describe "encode_request/1 - messages" do
    test "encodes user message with string content" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    end

    test "encodes user message with multimodal content" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{url: "https://example.com/img.png"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      [msg] = payload["messages"]
      assert [text_part, image_part] = msg["content"]
      assert text_part == %{"type" => "text", "text" => "describe this"}

      assert image_part == %{
               "type" => "image",
               "source" => %{"type" => "url", "url" => "https://example.com/img.png"}
             }
    end

    test "encodes image with base64 data" do
      parts = [%Content.Image{data: "abc123", media_type: "image/png"}]
      request = build_request([Message.user(parts)])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      [msg] = payload["messages"]
      [image_part] = msg["content"]

      assert image_part == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "abc123"
               }
             }
    end

    test "encodes assistant message" do
      request = build_request([Message.user("hi"), Message.assistant("hello")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert [_, %{"role" => "assistant", "content" => "hello"}] = payload["messages"]
    end

    test "encodes assistant message with tool_calls as tool_use content blocks" do
      tc = %ToolCall{id: "toolu_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      msg = %{Message.assistant("thinking...") | tool_calls: [tc]}
      request = build_request([Message.user("weather?"), msg])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      [_, assistant_msg] = payload["messages"]
      assert assistant_msg["role"] == "assistant"

      assert [
               %{"type" => "text", "text" => "thinking..."},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "get_weather",
                 "input" => %{"city" => "Paris"}
               }
             ] = assistant_msg["content"]
    end

    test "encodes assistant with tool_calls and nil content" do
      tc = %ToolCall{id: "toolu_1", name: "search", arguments: %{"q" => "elixir"}}
      msg = %{Message.assistant(nil) | tool_calls: [tc]}
      request = build_request([Message.user("find"), msg])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      [_, assistant_msg] = payload["messages"]

      assert [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "search",
                 "input" => %{"q" => "elixir"}
               }
             ] = assistant_msg["content"]
    end

    test "groups consecutive tool_result messages into a single user message" do
      tc1 = %ToolCall{id: "toolu_1", name: "weather", arguments: %{}}
      tc2 = %ToolCall{id: "toolu_2", name: "search", arguments: %{}}
      msg1 = Message.tool_result(tc1, "22C")
      msg2 = Message.tool_result(tc2, "found it")

      request = build_request([Message.user("hi"), msg1, msg2])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert [
               %{"role" => "user", "content" => "hi"},
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "22C"},
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_2",
                     "content" => "found it"
                   }
                 ]
               }
             ] = payload["messages"]
    end

    test "includes model in payload" do
      request = build_request([Message.user("hi")], model: "claude-sonnet-4-20250514")
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["model"] == "claude-sonnet-4-20250514"
    end
  end

  describe "encode_request/1 - params" do
    test "defaults max_tokens to 4096 when nil" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["max_tokens"] == 4096
    end

    test "uses provided max_tokens" do
      request = build_request([Message.user("hi")], params: %{max_tokens: 1000})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["max_tokens"] == 1000
    end

    test "translates temperature" do
      request = build_request([Message.user("hi")], params: %{temperature: 0.7})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["temperature"] == 0.7
    end

    test "translates top_k" do
      request = build_request([Message.user("hi")], params: %{top_k: 40})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["top_k"] == 40
    end

    test "translates stop to stop_sequences" do
      request = build_request([Message.user("hi")], params: %{stop: ["END", "STOP"]})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["stop_sequences"] == ["END", "STOP"]
    end

    test "drops unsupported params" do
      params = %{
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.3,
        parallel_tool_calls: true
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      refute Map.has_key?(payload, "seed")
      refute Map.has_key?(payload, "frequency_penalty")
      refute Map.has_key?(payload, "presence_penalty")
      refute Map.has_key?(payload, "parallel_tool_calls")
    end

    test "translates tool_choice :auto" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :auto})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["tool_choice"] == %{"type" => "auto"}
    end

    test "translates tool_choice :none" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :none})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["tool_choice"] == %{"type" => "none"}
    end

    test "translates tool_choice :any" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :any})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["tool_choice"] == %{"type" => "any"}
    end

    test "translates tool_choice {:tool, name}" do
      request =
        build_request([Message.user("hi")], params: %{tool_choice: {:tool, "weather"}})

      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["tool_choice"] == %{"type" => "tool", "name" => "weather"}
    end
  end

  describe "encode_request/1 - thinking" do
    test "maps reasoning_effort :low to thinking with budget_tokens 1024" do
      request = build_request([Message.user("hi")], params: %{reasoning_effort: :low})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert payload["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
    end

    test "maps reasoning_effort :medium to thinking with budget_tokens 4096" do
      request = build_request([Message.user("hi")], params: %{reasoning_effort: :medium})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert payload["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}
    end

    test "maps reasoning_effort :high to thinking with budget_tokens 16384" do
      request = build_request([Message.user("hi")], params: %{reasoning_effort: :high})
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert payload["thinking"] == %{"type" => "enabled", "budget_tokens" => 16_384}
    end

    test "no thinking field when reasoning_effort is nil" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      refute Map.has_key?(payload, "thinking")
    end
  end

  describe "encode_request/1 - streaming" do
    test "sets stream true when callback present" do
      callback = fn _chunk -> :ok end
      request = build_request([Message.user("hi")], stream: callback)
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert payload["stream"] == true
    end

    test "does not set stream when nil" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      refute Map.has_key?(payload, "stream")
    end
  end

  describe "encode_request/1 - response schema" do
    test "encodes response schema as output_config" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => ["answer"]
      }

      request = build_request([Message.user("hi")], response_schema: schema)
      assert {:ok, payload} = AnthropicMessages.encode_request(request)

      assert %{"output_config" => %{"format" => %{"type" => "json_schema", "schema" => _}}} =
               payload
    end

    test "omits output_config when no schema" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      refute Map.has_key?(payload, "output_config")
    end
  end

  describe "encode_tools/1" do
    test "encodes tools with input_schema format" do
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

      assert {:ok, [encoded]} = AnthropicMessages.encode_tools(tools)
      assert encoded["name"] == "get_weather"
      assert encoded["description"] == "Get current weather"
      assert encoded["input_schema"]["type"] == "object"
      assert encoded["input_schema"]["properties"]["city"]["type"] == "string"
      refute Map.has_key?(encoded, "type")
      refute Map.has_key?(encoded, "strict")
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
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      assert [tool] = payload["tools"]
      assert tool["name"] == "search"
    end

    test "omits tools key when tools list is empty" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = AnthropicMessages.encode_request(request)
      refute Map.has_key?(payload, "tools")
    end
  end

  describe "encode_response_schema/1" do
    test "converts to JSON schema without wrapper" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "score" => %{"type" => "number"}
        },
        "required" => ["name", "score"]
      }

      assert {:ok, json_schema} = AnthropicMessages.encode_response_schema(schema)

      assert json_schema["type"] == "object"
      assert json_schema["properties"]["name"]["type"] == "string"
    end
  end

  describe "decode_response/1 - text responses" do
    test "decodes a simple text response" do
      body = anthropic_response(content: [%{"type" => "text", "text" => "Hello there!"}])
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.text == "Hello there!"
      assert resp.tool_calls == []
      assert resp.model == "claude-sonnet-4-20250514"
      assert resp.finish_reason == :stop
    end

    test "decodes usage tokens" do
      body = anthropic_response(content: [%{"type" => "text", "text" => "hi"}])
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 25
    end

    test "decodes usage with cache tokens" do
      body =
        anthropic_response(
          content: [%{"type" => "text", "text" => "hi"}],
          usage: %{
            "input_tokens" => 10,
            "output_tokens" => 25,
            "cache_creation_input_tokens" => 100,
            "cache_read_input_tokens" => 50
          }
        )

      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.usage.cache_creation_input_tokens == 100
      assert resp.usage.cache_read_input_tokens == 50
    end

    test "preserves raw response body" do
      body = anthropic_response(content: [%{"type" => "text", "text" => "hi"}])
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.raw == body
    end

    test "returns placeholder context with empty messages" do
      body = anthropic_response(content: [%{"type" => "text", "text" => "hi"}])
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.context.messages == []
    end
  end

  describe "decode_response/1 - tool_use" do
    test "decodes tool_use blocks" do
      content = [
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "get_weather",
          "input" => %{"city" => "Paris"}
        }
      ]

      body = anthropic_response(content: content)
      assert {:ok, resp} = AnthropicMessages.decode_response(body)

      assert [tc] = resp.tool_calls
      assert tc.id == "toolu_1"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Paris"}
      assert resp.finish_reason == :stop
    end

    test "decodes mixed text and tool_use" do
      content = [
        %{"type" => "text", "text" => "Let me check..."},
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "weather",
          "input" => %{"city" => "NYC"}
        }
      ]

      body = anthropic_response(content: content)
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.text == "Let me check..."
      assert [tc] = resp.tool_calls
      assert tc.name == "weather"
    end
  end

  describe "decode_response/1 - thinking" do
    test "decodes thinking blocks into reasoning summary" do
      content = [
        %{"type" => "thinking", "thinking" => "Let me reason about this..."},
        %{"type" => "text", "text" => "The answer is 42."}
      ]

      body = anthropic_response(content: content)
      assert {:ok, resp} = AnthropicMessages.decode_response(body)

      assert [%Sycophant.Message.Content.Thinking{text: "Let me reason about this..."}] =
               resp.reasoning.content

      assert resp.text == "The answer is 42."
    end

    test "decodes redacted_thinking into encrypted_content" do
      content = [
        %{"type" => "redacted_thinking", "data" => "encrypted_data_here"},
        %{"type" => "text", "text" => "answer"}
      ]

      body = anthropic_response(content: content)
      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.reasoning == %Reasoning{encrypted_content: "encrypted_data_here"}
    end
  end

  describe "decode_response/1 - errors" do
    test "decodes overloaded error as ServerError" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      }

      assert {:error, %ServerError{}} = AnthropicMessages.decode_response(body)
    end

    test "decodes rate_limit_error as RateLimited" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "rate_limit_error", "message" => "Rate limited"}
      }

      assert {:error, %RateLimited{}} = AnthropicMessages.decode_response(body)
    end

    test "decodes api_error as ServerError" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "api_error", "message" => "Internal error"}
      }

      assert {:error, %ServerError{}} = AnthropicMessages.decode_response(body)
    end

    test "decodes other errors as ResponseInvalid" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "Bad request"}
      }

      assert {:error, %ResponseInvalid{}} = AnthropicMessages.decode_response(body)
    end

    test "returns error for unexpected body shape" do
      body = %{"unexpected" => "shape"}
      assert {:error, %ResponseInvalid{}} = AnthropicMessages.decode_response(body)
    end
  end

  describe "init_stream/0" do
    test "returns a StreamState struct" do
      state = AnthropicMessages.init_stream()

      assert %{
               text: "",
               tool_calls: %{},
               thinking: "",
               encrypted_thinking: nil,
               usage: nil,
               model: nil,
               current_block: nil
             } = state
    end
  end

  describe "decode_stream_chunk/2" do
    test "full streaming lifecycle" do
      state = AnthropicMessages.init_stream()

      # message_start
      event1 = %{
        event: "message_start",
        data: %{
          "message" => %{
            "model" => "claude-sonnet-4-20250514",
            "usage" => %{"input_tokens" => 15, "output_tokens" => 0}
          }
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event1)
      assert state.model == "claude-sonnet-4-20250514"
      assert state.usage.input_tokens == 15

      # content_block_start (text)
      event2 = %{
        event: "content_block_start",
        data: %{"index" => 0, "content_block" => %{"type" => "text", "text" => ""}}
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event2)

      # content_block_delta (text)
      event3 = %{
        event: "content_block_delta",
        data: %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}}
      }

      assert {:ok, state, [chunk]} = AnthropicMessages.decode_stream_chunk(state, event3)
      assert %StreamChunk{type: :text_delta, data: "Hello"} = chunk
      assert state.text == "Hello"

      # another text delta
      event4 = %{
        event: "content_block_delta",
        data: %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => " world"}}
      }

      assert {:ok, state, [chunk]} = AnthropicMessages.decode_stream_chunk(state, event4)
      assert chunk.data == " world"
      assert state.text == "Hello world"

      # content_block_stop
      event5 = %{event: "content_block_stop", data: %{"index" => 0}}
      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event5)

      # message_delta
      event6 = %{
        event: "message_delta",
        data: %{
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 15}
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event6)
      assert state.usage.output_tokens == 15

      # message_stop
      event7 = %{event: "message_stop", data: %{}}

      assert {:done, %Response{} = response} =
               AnthropicMessages.decode_stream_chunk(state, event7)

      assert response.text == "Hello world"
      assert response.tool_calls == []
      assert response.model == "claude-sonnet-4-20250514"
      assert response.usage.input_tokens == 15
      assert response.usage.output_tokens == 15
      assert response.finish_reason == :stop
    end

    test "streaming with tool_use" do
      state = AnthropicMessages.init_stream()

      # message_start
      event1 = %{
        event: "message_start",
        data: %{
          "message" => %{
            "model" => "claude-sonnet-4-20250514",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
          }
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event1)

      # content_block_start (tool_use)
      event2 = %{
        event: "content_block_start",
        data: %{
          "index" => 0,
          "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "weather"}
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event2)

      # input_json_delta
      event3 = %{
        event: "content_block_delta",
        data: %{
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cit"}
        }
      }

      assert {:ok, state, [chunk]} = AnthropicMessages.decode_stream_chunk(state, event3)
      assert %StreamChunk{type: :tool_call_delta} = chunk

      # more input_json_delta
      event4 = %{
        event: "content_block_delta",
        data: %{
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "y\":\"Paris\"}"}
        }
      }

      assert {:ok, state, [_chunk]} = AnthropicMessages.decode_stream_chunk(state, event4)

      # content_block_stop
      event5 = %{event: "content_block_stop", data: %{"index" => 0}}
      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event5)

      # message_delta
      event6 = %{
        event: "message_delta",
        data: %{
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 20}
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event6)

      # message_stop
      event7 = %{event: "message_stop", data: %{}}

      assert {:done, %Response{} = response} =
               AnthropicMessages.decode_stream_chunk(state, event7)

      assert response.text == nil
      assert [tc] = response.tool_calls
      assert tc.id == "toolu_1"
      assert tc.name == "weather"
      assert tc.arguments == %{"city" => "Paris"}
      assert response.finish_reason == :tool_use
    end

    test "streaming with thinking" do
      state = AnthropicMessages.init_stream()

      # message_start
      event1 = %{
        event: "message_start",
        data: %{
          "message" => %{
            "model" => "claude-sonnet-4-20250514",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
          }
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event1)

      # content_block_start (thinking)
      event2 = %{
        event: "content_block_start",
        data: %{
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => ""}
        }
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event2)

      # thinking_delta
      event3 = %{
        event: "content_block_delta",
        data: %{
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
        }
      }

      assert {:ok, state, [chunk]} = AnthropicMessages.decode_stream_chunk(state, event3)
      assert %StreamChunk{type: :reasoning_delta, data: "Let me think..."} = chunk
      assert state.thinking == "Let me think..."

      # content_block_stop for thinking
      event4 = %{event: "content_block_stop", data: %{"index" => 0}}
      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event4)

      # text block
      event5 = %{
        event: "content_block_start",
        data: %{"index" => 1, "content_block" => %{"type" => "text", "text" => ""}}
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event5)

      event6 = %{
        event: "content_block_delta",
        data: %{"index" => 1, "delta" => %{"type" => "text_delta", "text" => "42"}}
      }

      assert {:ok, state, [_]} = AnthropicMessages.decode_stream_chunk(state, event6)

      # finish
      event7 = %{
        event: "message_delta",
        data: %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 30}}
      }

      assert {:ok, state, []} = AnthropicMessages.decode_stream_chunk(state, event7)

      event8 = %{event: "message_stop", data: %{}}

      assert {:done, %Response{} = response} =
               AnthropicMessages.decode_stream_chunk(state, event8)

      assert response.text == "42"

      assert [%Sycophant.Message.Content.Thinking{text: "Let me think..."}] =
               response.reasoning.content

      assert response.finish_reason == :stop
    end

    test "skips ping events" do
      state = AnthropicMessages.init_stream()
      event = %{event: "ping", data: %{}}
      assert {:ok, ^state, []} = AnthropicMessages.decode_stream_chunk(state, event)
    end
  end

  describe "map_finish_reason/1" do
    test "maps provider-specific values to canonical atoms" do
      base_content = [%{"type" => "text", "text" => "hi"}]

      for {provider_value, expected_atom} <- [
            {"end_turn", :stop},
            {"tool_use", :tool_use},
            {"max_tokens", :max_tokens}
          ] do
        body = %{
          anthropic_response(content: base_content)
          | "stop_reason" => provider_value
        }

        assert {:ok, resp} = AnthropicMessages.decode_response(body)
        assert resp.finish_reason == expected_atom
      end
    end

    test "maps nil to nil" do
      body = %{
        anthropic_response(content: [%{"type" => "text", "text" => "hi"}])
        | "stop_reason" => nil
      }

      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.finish_reason == nil
    end

    test "maps unknown values to :unknown" do
      body = %{
        anthropic_response(content: [%{"type" => "text", "text" => "hi"}])
        | "stop_reason" => "something_new"
      }

      assert {:ok, resp} = AnthropicMessages.decode_response(body)
      assert resp.finish_reason == :unknown
    end
  end

  describe "param_schema/0" do
    test "validates supported params" do
      schema = AnthropicMessages.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7})
      assert result.temperature == 0.7
    end

    test "strips unsupported params" do
      schema = AnthropicMessages.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7, unknown_param: true})
      refute Map.has_key?(result, :unknown_param)
    end

    test "rejects invalid values" do
      schema = AnthropicMessages.param_schema()
      assert {:error, _} = Zoi.parse(schema, %{temperature: 5.0})
    end

    test "accepts all shared params" do
      schema = AnthropicMessages.param_schema()

      assert {:ok, result} =
               Zoi.parse(schema, %{
                 temperature: 0.5,
                 max_tokens: 100,
                 top_p: 0.9,
                 top_k: 40,
                 stop: ["END"],
                 reasoning_effort: :medium,
                 reasoning_summary: :auto,
                 service_tier: "default",
                 tool_choice: :auto,
                 parallel_tool_calls: true
               })

      assert result.temperature == 0.5
      assert result.max_tokens == 100
    end
  end

  # --- Helpers ---

  defp build_request(messages, opts \\ []) do
    %Request{
      messages: messages,
      model: opts[:model] || "claude-sonnet-4-20250514",
      params: opts[:params] || %{},
      tools: opts[:tools] || [],
      response_schema: opts[:response_schema],
      stream: opts[:stream]
    }
  end

  defp anthropic_response(opts) do
    content = Keyword.fetch!(opts, :content)
    usage = Keyword.get(opts, :usage, %{"input_tokens" => 10, "output_tokens" => 25})

    %{
      "id" => "msg_test123",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => content,
      "stop_reason" => "end_turn",
      "usage" => usage
    }
  end
end
