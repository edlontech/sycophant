defmodule Sycophant.WireProtocol.OpenAICompletionsTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
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

  describe "encode_request/1 - wire-specific params" do
    test "wire-specific params like logprobs pass through via param_schema" do
      request = build_request([Message.user("hi")], params: %{logprobs: true, top_logprobs: 5})

      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["logprobs"] == true
      assert payload["top_logprobs"] == 5
    end
  end

  describe "encode_request/1 - params" do
    test "translates canonical params to OpenAI names" do
      params = %{temperature: 0.7, max_tokens: 1000, top_p: 0.9}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["temperature"] == 0.7
      assert payload["max_completion_tokens"] == 1000
      assert payload["top_p"] == 0.9
    end

    test "omits nil params" do
      params = %{temperature: 0.5}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["temperature"] == 0.5
      refute Map.has_key?(payload, "max_completion_tokens")
      refute Map.has_key?(payload, "top_p")
    end

    test "drops unsupported params" do
      params = %{
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

    test "translates reasoning_effort to reasoning_effort as string" do
      params = %{reasoning_effort: :medium}
      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["reasoning_effort"] == "medium"
    end

    test "translates stop sequences" do
      params = %{stop: ["END", "STOP"]}
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
          parameters: %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
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
          parameters: %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          }
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
  end

  describe "encode_response_schema/1" do
    test "encodes JSON Schema to OpenAI response_format" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "score" => %{"type" => "number"}
        },
        "required" => ["name", "score"]
      }

      assert {:ok, format} = OpenAICompletions.encode_response_schema(schema)

      assert format["type"] == "json_schema"
      assert format["json_schema"]["name"] == "response"
      assert format["json_schema"]["strict"] == true
      assert format["json_schema"]["schema"]["type"] == "object"
      assert format["json_schema"]["schema"]["additionalProperties"] == false
    end

    test "includes response_format in request payload" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => ["answer"]
      }

      request = build_request([Message.user("hi")], response_schema: schema)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["response_format"]["type"] == "json_schema"
    end

    test "omits response_format when no schema" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      refute Map.has_key?(payload, "response_format")
    end
  end

  describe "decode_response/1 - text responses" do
    test "decodes a simple text response" do
      body = openai_response(content: "Hello there!")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.text == "Hello there!"
      assert resp.tool_calls == []
      assert resp.model == "gpt-4o-2024-08-06"
      assert resp.finish_reason == :stop
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
      assert resp.finish_reason == :stop
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

  describe "map_finish_reason/1" do
    test "maps provider-specific values to canonical atoms" do
      for {provider_value, expected_atom} <- [
            {"stop", :stop},
            {"tool_calls", :tool_use},
            {"length", :max_tokens},
            {"content_filter", :content_filter}
          ] do
        body =
          openai_response(content: "hi")
          |> put_in(["choices", Access.at(0), "finish_reason"], provider_value)

        assert {:ok, resp} = OpenAICompletions.decode_response(body)
        assert resp.finish_reason == expected_atom
      end
    end

    test "maps nil to nil" do
      body =
        openai_response(content: "hi")
        |> put_in(["choices", Access.at(0), "finish_reason"], nil)

      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.finish_reason == nil
    end

    test "maps unknown values to :unknown" do
      body =
        openai_response(content: "hi")
        |> put_in(["choices", Access.at(0), "finish_reason"], "something_new")

      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.finish_reason == :unknown
    end
  end

  describe "param_schema/0" do
    test "validates supported params" do
      schema = OpenAICompletions.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7})
      assert result.temperature == 0.7
    end

    test "strips unsupported params" do
      schema = OpenAICompletions.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7, unknown_param: true})
      refute Map.has_key?(result, :unknown_param)
    end

    test "rejects invalid values" do
      schema = OpenAICompletions.param_schema()
      assert {:error, _} = Zoi.parse(schema, %{temperature: 5.0})
    end

    test "accepts wire-specific extras" do
      schema = OpenAICompletions.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{logprobs: true, seed: 42})
      assert result.logprobs == true
      assert result.seed == 42
    end

    test "validates frequency_penalty bounds" do
      schema = OpenAICompletions.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{frequency_penalty: 1.0})
      assert result.frequency_penalty == 1.0
      assert {:error, _} = Zoi.parse(schema, %{frequency_penalty: 3.0})
    end

    test "validates presence_penalty bounds" do
      schema = OpenAICompletions.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{presence_penalty: -1.5})
      assert result.presence_penalty == -1.5
      assert {:error, _} = Zoi.parse(schema, %{presence_penalty: 2.5})
    end
  end

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

  defp stream_event(data) when is_map(data), do: %{data: data}

  describe "encode_request/1 - streaming" do
    test "adds stream fields when request.stream is set" do
      callback = fn _chunk -> :ok end
      request = build_request([Message.user("hi")], stream: callback)
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["stream"] == true
      assert payload["stream_options"] == %{"include_usage" => true}
    end

    test "does not add stream fields when stream is nil" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      refute Map.has_key?(payload, "stream")
      refute Map.has_key?(payload, "stream_options")
    end
  end

  describe "init_stream/0" do
    test "returns a StreamState struct" do
      state = OpenAICompletions.init_stream()
      assert %{text: "", tool_calls: %{}, usage: nil, model: nil} = state
    end
  end

  describe "decode_stream_chunk/2 - text deltas" do
    test "returns StreamChunk with type :text_delta" do
      state = OpenAICompletions.init_stream()

      event =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
          ]
        })

      assert {:ok, new_state, [chunk]} = OpenAICompletions.decode_stream_chunk(state, event)
      assert %StreamChunk{type: :text_delta, data: "Hello"} = chunk
      assert new_state.text == "Hello"
    end

    test "accumulates text across multiple chunks" do
      state = OpenAICompletions.init_stream()

      event1 =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
          ]
        })

      event2 =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => " world"}, "finish_reason" => nil}
          ]
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event1)
      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event2)
      assert state.text == "Hello world"
    end

    test "handles empty delta (role-only chunk)" do
      state = OpenAICompletions.init_stream()

      event =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"role" => "assistant"}, "finish_reason" => nil}
          ]
        })

      assert {:ok, _state, []} = OpenAICompletions.decode_stream_chunk(state, event)
    end
  end

  describe "decode_stream_chunk/2 - finish" do
    test "returns {:done, Response} on finish_reason stop" do
      state = OpenAICompletions.init_stream()

      event1 =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
          ]
        })

      event2 =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "model" => "gpt-4o"
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event1)

      assert {:done, %Response{} = response} =
               OpenAICompletions.decode_stream_chunk(state, event2)

      assert response.text == "Hello"
      assert response.tool_calls == []
      assert response.context.messages == []
      assert response.finish_reason == :stop
    end

    test "returns {:done, Response} on finish_reason tool_calls" do
      state = OpenAICompletions.init_stream()

      tc_event =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "weather", "arguments" => "{\"city\":\"Paris\"}"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      finish_event =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}],
          "model" => "gpt-4o"
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, tc_event)

      assert {:done, %Response{} = response} =
               OpenAICompletions.decode_stream_chunk(state, finish_event)

      assert [tool_call] = response.tool_calls
      assert tool_call.name == "weather"
      assert tool_call.arguments == %{"city" => "Paris"}
      assert response.finish_reason == :tool_use
    end

    test "sets text to nil when no text accumulated" do
      state = OpenAICompletions.init_stream()

      tc_event =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "weather", "arguments" => "{}"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      finish_event =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, tc_event)

      assert {:done, %Response{text: nil}} =
               OpenAICompletions.decode_stream_chunk(state, finish_event)
    end
  end

  describe "decode_stream_chunk/2 - tool call deltas" do
    test "accumulates tool call deltas with index and emits StreamChunk" do
      state = OpenAICompletions.init_stream()

      event =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "weather", "arguments" => "{\"ci"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      assert {:ok, state, [chunk]} = OpenAICompletions.decode_stream_chunk(state, event)
      assert %StreamChunk{type: :tool_call_delta} = chunk
      assert chunk.data.name == "weather"
      assert state.tool_calls[0].arguments == "{\"ci"
    end

    test "accumulates arguments across multiple tool call delta chunks" do
      state = OpenAICompletions.init_stream()

      event1 =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "weather", "arguments" => "{\"ci"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      event2 =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => "ty\":\"Paris\"}"}}
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event1)
      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event2)
      assert state.tool_calls[0].arguments == "{\"city\":\"Paris\"}"
    end

    test "assembles multiple tool calls sorted by index" do
      state = OpenAICompletions.init_stream()

      event1 =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "weather", "arguments" => "{\"city\":\"Paris\"}"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      event2 =
        stream_event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 1,
                    "id" => "call_2",
                    "function" => %{"name" => "search", "arguments" => "{\"q\":\"elixir\"}"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      finish_event =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event1)
      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event2)

      assert {:done, %Response{} = response} =
               OpenAICompletions.decode_stream_chunk(state, finish_event)

      assert [tc1, tc2] = response.tool_calls
      assert tc1.name == "weather"
      assert tc1.arguments == %{"city" => "Paris"}
      assert tc2.name == "search"
      assert tc2.arguments == %{"q" => "elixir"}
    end
  end

  describe "decode_stream_chunk/2 - [DONE] sentinel" do
    test "[DONE] sentinel returns empty chunks" do
      state = OpenAICompletions.init_stream()
      event = %{data: "[DONE]"}

      assert {:ok, _state, []} = OpenAICompletions.decode_stream_chunk(state, event)
    end
  end

  describe "decode_stream_chunk/2 - usage" do
    test "captures usage from chunk with usage field" do
      state = OpenAICompletions.init_stream()

      event =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}, "finish_reason" => nil}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
        })

      assert {:ok, state, _chunks} = OpenAICompletions.decode_stream_chunk(state, event)
      assert state.usage == %Sycophant.Usage{input_tokens: 10, output_tokens: 5}
    end

    test "usage appears in final response" do
      state = OpenAICompletions.init_stream()

      event1 =
        stream_event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
        })

      event2 =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "model" => "gpt-4o"
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event1)

      assert {:done, %Response{} = response} =
               OpenAICompletions.decode_stream_chunk(state, event2)

      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 5
    end
  end

  describe "decode_stream_chunk/2 - model capture" do
    test "captures model from chunk" do
      state = OpenAICompletions.init_stream()

      event =
        stream_event(%{
          "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}, "finish_reason" => nil}],
          "model" => "gpt-4o-2024-08-06"
        })

      assert {:ok, state, _} = OpenAICompletions.decode_stream_chunk(state, event)
      assert state.model == "gpt-4o-2024-08-06"
    end
  end

  describe "encode_request/1 - tool_choice" do
    test "encodes :auto as \"auto\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :auto})
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["tool_choice"] == "auto"
    end

    test "encodes :none as \"none\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :none})
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["tool_choice"] == "none"
    end

    test "encodes :any as \"required\"" do
      request = build_request([Message.user("hi")], params: %{tool_choice: :any})
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      assert payload["tool_choice"] == "required"
    end

    test "encodes {:tool, name} as function object" do
      request =
        build_request([Message.user("hi")], params: %{tool_choice: {:tool, "get_weather"}})

      assert {:ok, payload} = OpenAICompletions.encode_request(request)

      assert payload["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "get_weather"}
             }
    end

    test "omits tool_choice when nil" do
      request = build_request([Message.user("hi")], params: %{tool_choice: nil})
      assert {:ok, payload} = OpenAICompletions.encode_request(request)
      refute Map.has_key?(payload, "tool_choice")
    end
  end

  describe "decode_response/1 - cache usage" do
    test "decodes cached_tokens from prompt_tokens_details" do
      body =
        openai_response(content: "hi")
        |> put_in(
          ["usage", "prompt_tokens_details"],
          %{"cached_tokens" => 50}
        )

      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.usage.cache_read_input_tokens == 50
      assert resp.usage.cache_creation_input_tokens == nil
    end

    test "sets cache fields to nil when prompt_tokens_details is absent" do
      body = openai_response(content: "hi")
      assert {:ok, resp} = OpenAICompletions.decode_response(body)
      assert resp.usage.cache_read_input_tokens == nil
      assert resp.usage.cache_creation_input_tokens == nil
    end
  end

  describe "request_path/1" do
    test "returns /chat/completions" do
      assert OpenAICompletions.request_path(%Sycophant.Request{messages: []}) ==
               "/chat/completions"
    end
  end
end
