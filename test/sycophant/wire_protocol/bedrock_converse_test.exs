defmodule Sycophant.WireProtocol.BedrockConverseTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage
  alias Sycophant.WireProtocol.BedrockConverse

  describe "request_path/1" do
    test "returns non-streaming path" do
      request = build_request([Message.user("hi")])
      assert BedrockConverse.request_path(request) == "/model/test-model/converse"
    end

    test "returns streaming path when stream callback present" do
      request = build_request([Message.user("hi")], stream: fn _chunk -> :ok end)
      assert BedrockConverse.request_path(request) == "/model/test-model/converse-stream"
    end

    test "URL-encodes model IDs with colons" do
      request =
        build_request([Message.user("hi")], model: "anthropic.claude-3-5-sonnet-20241022-v2:0")

      assert BedrockConverse.request_path(request) ==
               "/model/anthropic.claude-3-5-sonnet-20241022-v2%3A0/converse"
    end
  end

  describe "encode_request/1 - system messages" do
    test "extracts system messages into top-level system array" do
      request = build_request([Message.system("be helpful"), Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      assert payload["system"] == [%{"text" => "be helpful"}]
      assert [%{"role" => "user"}] = payload["messages"]
    end

    test "concatenates multiple system messages" do
      request =
        build_request([
          Message.system("be helpful"),
          Message.system("be concise"),
          Message.user("hi")
        ])

      assert {:ok, payload} = BedrockConverse.encode_request(request)

      assert payload["system"] == [
               %{"text" => "be helpful"},
               %{"text" => "be concise"}
             ]
    end

    test "omits system field when no system messages" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "system")
    end
  end

  describe "encode_request/1 - messages" do
    test "encodes user message with text content as array of content blocks" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      assert [%{"role" => "user", "content" => [%{"text" => "hello"}]}] = payload["messages"]
    end

    test "encodes user message with multimodal content" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{data: "abc123", media_type: "image/jpeg"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      [msg] = payload["messages"]

      assert [
               %{"text" => "describe this"},
               %{"image" => %{"format" => "jpeg", "source" => %{"bytes" => "abc123"}}}
             ] = msg["content"]
    end

    test "encodes assistant message with tool calls using toolUse format" do
      tc = %ToolCall{id: "tc_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      msg = %{Message.assistant("thinking...") | tool_calls: [tc]}
      request = build_request([Message.user("weather?"), msg])
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      [_, assistant_msg] = payload["messages"]
      assert assistant_msg["role"] == "assistant"

      assert [
               %{"text" => "thinking..."},
               %{
                 "toolUse" => %{
                   "toolUseId" => "tc_1",
                   "name" => "get_weather",
                   "input" => %{"city" => "Paris"}
                 }
               }
             ] = assistant_msg["content"]
    end

    test "encodes tool result message using toolResult format" do
      tc = %ToolCall{id: "tc_1", name: "weather", arguments: %{}}
      msg = Message.tool_result(tc, "22C and sunny")

      request = build_request([Message.user("hi"), msg])
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      [_, tool_msg] = payload["messages"]
      assert tool_msg["role"] == "user"

      assert [
               %{
                 "toolResult" => %{
                   "toolUseId" => "tc_1",
                   "content" => [%{"text" => "22C and sunny"}]
                 }
               }
             ] = tool_msg["content"]
    end

    test "does not include model in request body" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "model")
    end
  end

  describe "encode_request/1 - params" do
    test "translates params to inferenceConfig" do
      params = %{
        max_tokens: 1000,
        temperature: 0.7,
        top_p: 0.9,
        stop: ["END", "STOP"]
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      assert payload["inferenceConfig"] == %{
               "maxTokens" => 1000,
               "temperature" => 0.7,
               "topP" => 0.9,
               "stopSequences" => ["END", "STOP"]
             }
    end

    test "omits inferenceConfig when no params are set" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "inferenceConfig")
    end

    test "omits inferenceConfig when all params are nil" do
      request = build_request([Message.user("hi")], params: %{})
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "inferenceConfig")
    end

    test "drops unsupported params" do
      params = %{
        top_k: 40,
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.3,
        parallel_tool_calls: true,
        temperature: 0.5
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = BedrockConverse.encode_request(request)

      config = payload["inferenceConfig"]
      assert config["temperature"] == 0.5
      refute Map.has_key?(config, "topK")
      refute Map.has_key?(config, "seed")
      refute Map.has_key?(config, "frequencyPenalty")
      refute Map.has_key?(config, "presencePenalty")
    end
  end

  describe "encode_request/1 - tool choice" do
    test "translates tool_choice :auto" do
      tools = [
        %Tool{
          name: "search",
          description: "Search",
          parameters: Zoi.map(%{q: Zoi.string()})
        }
      ]

      request =
        build_request([Message.user("hi")], tools: tools, params: %{tool_choice: :auto})

      assert {:ok, payload} = BedrockConverse.encode_request(request)
      assert payload["toolConfig"]["toolChoice"] == %{"auto" => %{}}
    end

    test "translates tool_choice :any" do
      tools = [
        %Tool{
          name: "search",
          description: "Search",
          parameters: Zoi.map(%{q: Zoi.string()})
        }
      ]

      request =
        build_request([Message.user("hi")], tools: tools, params: %{tool_choice: :any})

      assert {:ok, payload} = BedrockConverse.encode_request(request)
      assert payload["toolConfig"]["toolChoice"] == %{"any" => %{}}
    end

    test "translates tool_choice {:tool, name}" do
      tools = [
        %Tool{
          name: "weather",
          description: "Get weather",
          parameters: Zoi.map(%{city: Zoi.string()})
        }
      ]

      request =
        build_request([Message.user("hi")],
          tools: tools,
          params: %{tool_choice: {:tool, "weather"}}
        )

      assert {:ok, payload} = BedrockConverse.encode_request(request)
      assert payload["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "weather"}}
    end
  end

  describe "encode_tools/1" do
    test "encodes tools with toolSpec format and inputSchema.json" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get current weather",
          parameters: Zoi.map(%{city: Zoi.string()})
        }
      ]

      assert {:ok, [encoded]} = BedrockConverse.encode_tools(tools)
      spec = encoded["toolSpec"]
      assert spec["name"] == "get_weather"
      assert spec["description"] == "Get current weather"
      assert spec["inputSchema"]["json"]["type"] == "object"
      assert spec["inputSchema"]["json"]["properties"]["city"]["type"] == "string"
    end

    test "encodes tools in request payload under toolConfig" do
      tools = [
        %Tool{
          name: "search",
          description: "Search the web",
          parameters: Zoi.map(%{query: Zoi.string()})
        }
      ]

      request = build_request([Message.user("hi")], tools: tools)
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      assert [tool] = payload["toolConfig"]["tools"]
      assert tool["toolSpec"]["name"] == "search"
    end

    test "omits toolConfig when tools list is empty" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "toolConfig")
    end
  end

  describe "encode_request/1 - empty params" do
    test "handles empty params map" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = BedrockConverse.encode_request(request)
      refute Map.has_key?(payload, "inferenceConfig")
    end
  end

  describe "decode_response/1" do
    test "decodes text response" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"text" => "Hello!"}]
          }
        },
        "stopReason" => "end_turn",
        "usage" => %{"inputTokens" => 30, "outputTokens" => 100, "totalTokens" => 130}
      }

      assert {:ok, %Response{} = response} = BedrockConverse.decode_response(body)
      assert response.text == "Hello!"
      assert response.tool_calls == []
      assert %Usage{input_tokens: 30, output_tokens: 100} = response.usage
      assert response.raw == body
      assert response.finish_reason == :stop
    end

    test "decodes tool use response with text and tool calls" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"text" => "Let me check the weather."},
              %{
                "toolUse" => %{
                  "toolUseId" => "tc1",
                  "name" => "get_weather",
                  "input" => %{"city" => "NYC"}
                }
              }
            ]
          }
        },
        "stopReason" => "tool_use",
        "usage" => %{"inputTokens" => 50, "outputTokens" => 80, "totalTokens" => 130}
      }

      assert {:ok, %Response{} = response} = BedrockConverse.decode_response(body)
      assert response.text == "Let me check the weather."

      assert [%ToolCall{id: "tc1", name: "get_weather", arguments: %{"city" => "NYC"}}] =
               response.tool_calls

      assert response.finish_reason == :tool_use
    end

    test "decodes response with only tool use and no text" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "toolUse" => %{
                  "toolUseId" => "tc2",
                  "name" => "search",
                  "input" => %{"query" => "elixir"}
                }
              }
            ]
          }
        },
        "stopReason" => "tool_use",
        "usage" => %{"inputTokens" => 10, "outputTokens" => 20, "totalTokens" => 30}
      }

      assert {:ok, %Response{} = response} = BedrockConverse.decode_response(body)
      assert response.text == nil

      assert [%ToolCall{id: "tc2", name: "search", arguments: %{"query" => "elixir"}}] =
               response.tool_calls

      assert response.finish_reason == :tool_use
    end

    test "returns error for invalid body structure" do
      assert {:error, %ResponseInvalid{}} = BedrockConverse.decode_response(%{"bad" => "data"})
      assert {:error, %ResponseInvalid{}} = BedrockConverse.decode_response(%{})
    end

    test "handles nil/missing usage gracefully" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"text" => "Hello"}]
          }
        },
        "stopReason" => "end_turn"
      }

      assert {:ok, %Response{} = response} = BedrockConverse.decode_response(body)
      assert response.text == "Hello"
      assert response.usage == nil
    end
  end

  describe "streaming" do
    test "init_stream returns empty StreamState" do
      state = BedrockConverse.init_stream()
      assert %{text: "", tool_calls: %{}, usage: nil, model: nil, current_block: nil} = state
    end

    test "full text streaming sequence" do
      state = BedrockConverse.init_stream()

      assert {:ok, state, []} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "messageStart",
                 payload: %{"role" => "assistant"}
               })

      assert {:ok, state, []} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "contentBlockStart",
                 payload: %{"contentBlockIndex" => 0}
               })

      assert {:ok, state, [%StreamChunk{type: :text_delta, data: "Hello"}]} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "contentBlockDelta",
                 payload: %{"contentBlockIndex" => 0, "delta" => %{"text" => "Hello"}}
               })

      assert {:ok, state, [%StreamChunk{type: :text_delta, data: " world"}]} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "contentBlockDelta",
                 payload: %{"contentBlockIndex" => 0, "delta" => %{"text" => " world"}}
               })

      assert {:ok, state, []} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "contentBlockStop",
                 payload: %{"contentBlockIndex" => 0}
               })

      assert {:ok, state, []} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "messageStop",
                 payload: %{"stopReason" => "end_turn"}
               })

      assert {:done, %Response{} = response} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "metadata",
                 payload: %{
                   "usage" => %{"inputTokens" => 10, "outputTokens" => 25},
                   "metrics" => %{"latencyMs" => 200}
                 }
               })

      assert response.text == "Hello world"
      assert response.tool_calls == []
      assert %Usage{input_tokens: 10, output_tokens: 25} = response.usage
      assert response.finish_reason == :stop
    end

    test "tool use streaming sequence" do
      state = BedrockConverse.init_stream()

      {:ok, state, []} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "messageStart",
          payload: %{"role" => "assistant"}
        })

      {:ok, state, []} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "contentBlockStart",
          payload: %{
            "contentBlockIndex" => 0,
            "start" => %{"toolUse" => %{"toolUseId" => "tc1", "name" => "get_weather"}}
          }
        })

      {:ok, state, [%StreamChunk{type: :tool_call_delta, index: 0} = chunk]} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "contentBlockDelta",
          payload: %{
            "contentBlockIndex" => 0,
            "delta" => %{"toolUse" => %{"input" => "{\"city\":"}}
          }
        })

      assert chunk.data.id == "tc1"
      assert chunk.data.name == "get_weather"
      assert chunk.data.arguments_delta == "{\"city\":"

      {:ok, state, [%StreamChunk{type: :tool_call_delta}]} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "contentBlockDelta",
          payload: %{
            "contentBlockIndex" => 0,
            "delta" => %{"toolUse" => %{"input" => "\"NYC\"}"}}
          }
        })

      {:ok, state, []} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "contentBlockStop",
          payload: %{"contentBlockIndex" => 0}
        })

      {:ok, state, []} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "messageStop",
          payload: %{"stopReason" => "tool_use"}
        })

      {:done, %Response{} = response} =
        BedrockConverse.decode_stream_chunk(state, %{
          event_type: "metadata",
          payload: %{
            "usage" => %{"inputTokens" => 50, "outputTokens" => 30},
            "metrics" => %{"latencyMs" => 150}
          }
        })

      assert response.text == nil

      assert [%ToolCall{id: "tc1", name: "get_weather", arguments: %{"city" => "NYC"}}] =
               response.tool_calls

      assert %Usage{input_tokens: 50, output_tokens: 30} = response.usage
      assert response.finish_reason == :tool_use
    end

    test "metadata event provides usage and completes stream" do
      state = BedrockConverse.init_stream()
      state = %{state | text: "done"}

      assert {:done, %Response{} = response} =
               BedrockConverse.decode_stream_chunk(state, %{
                 event_type: "metadata",
                 payload: %{
                   "usage" => %{"inputTokens" => 5, "outputTokens" => 10},
                   "metrics" => %{}
                 }
               })

      assert response.text == "done"
      assert %Usage{input_tokens: 5, output_tokens: 10} = response.usage
    end

    test "unknown events return ok with empty chunks" do
      state = BedrockConverse.init_stream()

      assert {:ok, ^state, []} =
               BedrockConverse.decode_stream_chunk(state, %{event_type: "ping", payload: %{}})

      assert {:ok, ^state, []} = BedrockConverse.decode_stream_chunk(state, %{})
    end
  end

  describe "map_finish_reason/1" do
    test "maps provider-specific values to canonical atoms" do
      base_body = fn stop_reason ->
        %{
          "output" => %{
            "message" => %{
              "role" => "assistant",
              "content" => [%{"text" => "hi"}]
            }
          },
          "stopReason" => stop_reason,
          "usage" => %{"inputTokens" => 10, "outputTokens" => 5, "totalTokens" => 15}
        }
      end

      for {provider_value, expected_atom} <- [
            {"end_turn", :stop},
            {"tool_use", :tool_use},
            {"max_tokens", :max_tokens}
          ] do
        assert {:ok, resp} = BedrockConverse.decode_response(base_body.(provider_value))
        assert resp.finish_reason == expected_atom
      end
    end

    test "maps nil to nil" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"text" => "hi"}]
          }
        },
        "stopReason" => nil,
        "usage" => %{"inputTokens" => 10, "outputTokens" => 5, "totalTokens" => 15}
      }

      assert {:ok, resp} = BedrockConverse.decode_response(body)
      assert resp.finish_reason == nil
    end

    test "maps unknown values to :unknown" do
      body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"text" => "hi"}]
          }
        },
        "stopReason" => "something_new",
        "usage" => %{"inputTokens" => 10, "outputTokens" => 5, "totalTokens" => 15}
      }

      assert {:ok, resp} = BedrockConverse.decode_response(body)
      assert resp.finish_reason == :unknown
    end
  end

  describe "param_schema/0" do
    test "validates supported params" do
      schema = BedrockConverse.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7})
      assert result.temperature == 0.7
    end

    test "strips unsupported params" do
      schema = BedrockConverse.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.7, unknown_param: true})
      refute Map.has_key?(result, :unknown_param)
    end

    test "rejects invalid values" do
      schema = BedrockConverse.param_schema()
      assert {:error, _} = Zoi.parse(schema, %{temperature: 5.0})
    end

    test "excludes shared params not in subset" do
      schema = BedrockConverse.param_schema()
      assert {:ok, result} = Zoi.parse(schema, %{temperature: 0.5, top_k: 40, reasoning: :high})
      assert result.temperature == 0.5
      refute Map.has_key?(result, :top_k)
      refute Map.has_key?(result, :reasoning)
    end

    test "accepts subset params" do
      schema = BedrockConverse.param_schema()

      assert {:ok, result} =
               Zoi.parse(schema, %{
                 temperature: 0.5,
                 max_tokens: 100,
                 top_p: 0.9,
                 stop: ["END"],
                 tool_choice: :auto,
                 parallel_tool_calls: true
               })

      assert result.temperature == 0.5
      assert result.max_tokens == 100
    end
  end

  defp build_request(messages, opts \\ []) do
    %Request{
      messages: messages,
      model: opts[:model] || "test-model",
      params: opts[:params] || %{},
      tools: opts[:tools] || [],
      stream: opts[:stream]
    }
  end
end
