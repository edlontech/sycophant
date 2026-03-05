defmodule Sycophant.WireProtocol.GoogleGeminiTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Params
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.WireProtocol.GoogleGemini

  describe "request_path/1" do
    test "returns generateContent path for non-streaming" do
      request = %Request{messages: [], model: "gemini-2.0-flash"}

      assert GoogleGemini.request_path(request) ==
               "/models/gemini-2.0-flash:generateContent"
    end

    test "returns streamGenerateContent path for streaming" do
      callback = fn _chunk -> :ok end
      request = %Request{messages: [], model: "gemini-2.0-flash", stream: callback}

      assert GoogleGemini.request_path(request) ==
               "/models/gemini-2.0-flash:streamGenerateContent?alt=sse"
    end
  end

  describe "encode_request/1 - system messages" do
    test "extracts system messages into system_instruction" do
      request = build_request([Message.system("be helpful"), Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["system_instruction"] == %{"parts" => [%{"text" => "be helpful"}]}
      assert [%{"role" => "user"}] = payload["contents"]
    end

    test "concatenates multiple system messages" do
      request =
        build_request([
          Message.system("be helpful"),
          Message.system("be concise"),
          Message.user("hi")
        ])

      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["system_instruction"] == %{
               "parts" => [%{"text" => "be helpful\nbe concise"}]
             }
    end

    test "omits system_instruction when no system messages" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "system_instruction")
    end
  end

  describe "encode_request/1 - messages" do
    test "encodes user message with parts format" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert [%{"role" => "user", "parts" => [%{"text" => "hello"}]}] = payload["contents"]
    end

    test "encodes assistant message as model role" do
      request = build_request([Message.user("hi"), Message.assistant("hello")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert [
               %{"role" => "user", "parts" => [%{"text" => "hi"}]},
               %{"role" => "model", "parts" => [%{"text" => "hello"}]}
             ] = payload["contents"]
    end

    test "encodes multipart content with text and base64 image" do
      parts = [
        %Content.Text{text: "describe this"},
        %Content.Image{data: "abc123", media_type: "image/png"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      [msg] = payload["contents"]

      assert [
               %{"text" => "describe this"},
               %{"inlineData" => %{"mimeType" => "image/png", "data" => "abc123"}}
             ] = msg["parts"]
    end

    test "encodes multipart content with URL image" do
      parts = [
        %Content.Text{text: "what is this"},
        %Content.Image{url: "https://example.com/img.png"}
      ]

      request = build_request([Message.user(parts)])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      [msg] = payload["contents"]

      assert [
               %{"text" => "what is this"},
               %{
                 "fileData" => %{
                   "fileUri" => "https://example.com/img.png",
                   "mimeType" => "image/*"
                 }
               }
             ] = msg["parts"]
    end

    test "encodes assistant with tool_calls as functionCall parts" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}
      msg = %{Message.assistant("thinking...") | tool_calls: [tc]}
      request = build_request([Message.user("weather?"), msg])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      [_, assistant_msg] = payload["contents"]
      assert assistant_msg["role"] == "model"

      assert [
               %{"text" => "thinking..."},
               %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Paris"}}}
             ] = assistant_msg["parts"]
    end

    test "encodes assistant with tool_calls and nil content" do
      tc = %ToolCall{id: "call_1", name: "search", arguments: %{"q" => "elixir"}}
      msg = %{Message.assistant(nil) | tool_calls: [tc]}
      request = build_request([Message.user("find"), msg])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      [_, assistant_msg] = payload["contents"]

      assert [
               %{"functionCall" => %{"name" => "search", "args" => %{"q" => "elixir"}}}
             ] = assistant_msg["parts"]
    end

    test "encodes tool_result messages as functionResponse parts" do
      tc = %ToolCall{id: "call_1", name: "get_weather", arguments: %{}}
      msg = %{Message.tool_result(tc, "22C sunny") | metadata: %{tool_name: "get_weather"}}
      request = build_request([Message.user("hi"), msg])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      [_, tool_msg] = payload["contents"]
      assert tool_msg["role"] == "user"

      assert [
               %{
                 "functionResponse" => %{
                   "name" => "get_weather",
                   "response" => %{"content" => "22C sunny"}
                 }
               }
             ] = tool_msg["parts"]
    end
  end

  describe "encode_request/1 - generationConfig" do
    test "assembles temperature, topP, topK, stopSequences, maxOutputTokens" do
      params = %Params{
        temperature: 0.7,
        top_p: 0.9,
        top_k: 40,
        stop: ["END", "STOP"],
        max_tokens: 1000
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      assert config["temperature"] == 0.7
      assert config["topP"] == 0.9
      assert config["topK"] == 40
      assert config["stopSequences"] == ["END", "STOP"]
      assert config["maxOutputTokens"] == 1000
    end

    test "omits generationConfig when no params set" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "generationConfig")
    end

    test "does not include model in body" do
      request = build_request([Message.user("hi")], model: "gemini-2.0-flash")
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "model")
    end

    test "does not include stream in body" do
      callback = fn _chunk -> :ok end
      request = build_request([Message.user("hi")], stream: callback)
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "stream")
    end
  end

  describe "encode_request/1 - dropped params" do
    test "drops unsupported params" do
      params = %Params{
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.3,
        parallel_tool_calls: true,
        cache_key: "abc",
        cache_retention: 300,
        safety_identifier: "safe",
        service_tier: "standard",
        reasoning_summary: :auto
      }

      request = build_request([Message.user("hi")], params: params)
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      refute Map.has_key?(payload, "seed")
      refute Map.has_key?(payload, "frequency_penalty")
      refute Map.has_key?(payload, "presence_penalty")
      refute Map.has_key?(payload, "parallel_tool_calls")
    end
  end

  describe "encode_request/1 - tool_choice" do
    test "maps :auto to toolConfig AUTO" do
      request = build_request([Message.user("hi")], params: %Params{tool_choice: :auto})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "AUTO"}}
    end

    test "maps :none to toolConfig NONE" do
      request = build_request([Message.user("hi")], params: %Params{tool_choice: :none})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "NONE"}}
    end

    test "maps :any to toolConfig ANY" do
      request = build_request([Message.user("hi")], params: %Params{tool_choice: :any})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "ANY"}}
    end

    test "maps {:tool, name} to toolConfig ANY with allowedFunctionNames" do
      request =
        build_request([Message.user("hi")], params: %Params{tool_choice: {:tool, "weather"}})

      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert payload["toolConfig"] == %{
               "functionCallingConfig" => %{
                 "mode" => "ANY",
                 "allowedFunctionNames" => ["weather"]
               }
             }
    end

    test "omits toolConfig when tool_choice is nil" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "toolConfig")
    end
  end

  describe "encode_request/1 - thinking" do
    test "maps reasoning :low to thinkingConfig LOW" do
      request = build_request([Message.user("hi")], params: %Params{reasoning: :low})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      assert config["thinkingConfig"] == %{"thinkingLevel" => "LOW"}
    end

    test "maps reasoning :medium to thinkingConfig MEDIUM" do
      request = build_request([Message.user("hi")], params: %Params{reasoning: :medium})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      assert config["thinkingConfig"] == %{"thinkingLevel" => "MEDIUM"}
    end

    test "maps reasoning :high to thinkingConfig HIGH" do
      request = build_request([Message.user("hi")], params: %Params{reasoning: :high})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      assert config["thinkingConfig"] == %{"thinkingLevel" => "HIGH"}
    end

    test "no thinkingConfig when reasoning is nil" do
      request = build_request([Message.user("hi")], params: %Params{temperature: 0.5})
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      refute Map.has_key?(config, "thinkingConfig")
    end
  end

  describe "encode_request/1 - response schema" do
    test "encodes response schema in generationConfig" do
      schema = Zoi.map(%{answer: Zoi.string()})
      request = build_request([Message.user("hi")], response_schema: schema)
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      config = payload["generationConfig"]
      assert config["responseMimeType"] == "application/json"
      assert config["responseSchema"]["type"] == "object"
      assert config["responseSchema"]["properties"]["answer"]["type"] == "string"
    end

    test "omits response schema fields when no schema" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      refute Map.has_key?(payload, "generationConfig") ||
               (is_map(payload["generationConfig"]) &&
                  Map.has_key?(payload["generationConfig"], "responseMimeType"))
    end
  end

  describe "encode_request/1 - provider_params" do
    test "merges provider_params into payload" do
      request = %Request{
        messages: [Message.user("hi")],
        model: "gemini-2.0-flash",
        provider_params: %{"safetySettings" => [%{"category" => "HARM"}]}
      }

      assert {:ok, payload} = GoogleGemini.encode_request(request)
      assert payload["safetySettings"] == [%{"category" => "HARM"}]
    end
  end

  describe "encode_tools/1" do
    test "encodes tools as functionDeclaration format" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get current weather",
          parameters: Zoi.map(%{city: Zoi.string()})
        }
      ]

      assert {:ok, [encoded]} = GoogleGemini.encode_tools(tools)
      assert encoded["name"] == "get_weather"
      assert encoded["description"] == "Get current weather"
      assert encoded["parameters"]["type"] == "object"
      assert encoded["parameters"]["properties"]["city"]["type"] == "string"
      refute Map.has_key?(encoded["parameters"], "additionalProperties")
      refute Map.has_key?(encoded, "type")
      refute Map.has_key?(encoded, "strict")
    end

    test "tools in request payload wrapped in functionDeclarations" do
      tools = [
        %Tool{
          name: "search",
          description: "Search the web",
          parameters: Zoi.map(%{query: Zoi.string()})
        }
      ]

      request = build_request([Message.user("hi")], tools: tools)
      assert {:ok, payload} = GoogleGemini.encode_request(request)

      assert [%{"functionDeclarations" => [tool]}] = payload["tools"]
      assert tool["name"] == "search"
    end

    test "omits tools key when tools list is empty" do
      request = build_request([Message.user("hi")])
      assert {:ok, payload} = GoogleGemini.encode_request(request)
      refute Map.has_key?(payload, "tools")
    end
  end

  describe "encode_response_schema/1" do
    test "returns plain JSON schema" do
      schema = Zoi.map(%{name: Zoi.string(), score: Zoi.float()})
      assert {:ok, json_schema} = GoogleGemini.encode_response_schema(schema)

      assert json_schema["type"] == "object"
      assert json_schema["properties"]["name"]["type"] == "string"
      refute Map.has_key?(json_schema, "additionalProperties")
    end
  end

  describe "decode_response/1 - text responses" do
    test "decodes a simple text response" do
      body = gemini_response(parts: [%{"text" => "Hello there!"}])
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.text == "Hello there!"
      assert resp.tool_calls == []
      assert resp.model == "gemini-2.0-flash"
    end

    test "decodes usage metadata" do
      body = gemini_response(parts: [%{"text" => "hi"}])
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 100
    end

    test "decodes usage with cache tokens" do
      body =
        gemini_response(
          parts: [%{"text" => "hi"}],
          usage: %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 100,
            "totalTokenCount" => 110,
            "cachedContentTokenCount" => 50
          }
        )

      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.usage.cache_read_input_tokens == 50
    end

    test "preserves raw response body" do
      body = gemini_response(parts: [%{"text" => "hi"}])
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.raw == body
    end

    test "returns placeholder context with empty messages" do
      body = gemini_response(parts: [%{"text" => "hi"}])
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.context.messages == []
    end
  end

  describe "decode_response/1 - tool calls" do
    test "decodes functionCall parts" do
      parts = [
        %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Paris"}}}
      ]

      body = gemini_response(parts: parts)
      assert {:ok, resp} = GoogleGemini.decode_response(body)

      assert [tc] = resp.tool_calls
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Paris"}
      assert tc.id == "gemini_call_0"
    end

    test "decodes mixed text and tool calls" do
      parts = [
        %{"text" => "Let me check..."},
        %{"functionCall" => %{"name" => "weather", "args" => %{"city" => "NYC"}}}
      ]

      body = gemini_response(parts: parts)
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.text == "Let me check..."
      assert [tc] = resp.tool_calls
      assert tc.name == "weather"
    end

    test "assigns sequential IDs to multiple tool calls" do
      parts = [
        %{"functionCall" => %{"name" => "tool_a", "args" => %{}}},
        %{"functionCall" => %{"name" => "tool_b", "args" => %{}}}
      ]

      body = gemini_response(parts: parts)
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert [tc1, tc2] = resp.tool_calls
      assert tc1.id == "gemini_call_0"
      assert tc2.id == "gemini_call_1"
    end
  end

  describe "decode_response/1 - thinking" do
    test "decodes thinking parts into reasoning summary" do
      parts = [
        %{"text" => "Let me reason...", "thought" => true},
        %{"text" => "The answer is 42"}
      ]

      body = gemini_response(parts: parts)
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.reasoning == %Reasoning{summary: "Let me reason..."}
      assert resp.text == "The answer is 42"
    end

    test "ignores thought: false as regular text" do
      parts = [
        %{"text" => "not thinking", "thought" => false},
        %{"text" => " more text"}
      ]

      body = gemini_response(parts: parts)
      assert {:ok, resp} = GoogleGemini.decode_response(body)
      assert resp.text == "not thinking more text"
      assert resp.reasoning == nil
    end
  end

  describe "decode_response/1 - errors" do
    test "decodes 429 error as RateLimited" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Resource exhausted",
          "status" => "RESOURCE_EXHAUSTED"
        }
      }

      assert {:error, %RateLimited{}} = GoogleGemini.decode_response(body)
    end

    test "decodes 500 error as ServerError" do
      body = %{
        "error" => %{
          "code" => 500,
          "message" => "Internal error",
          "status" => "INTERNAL"
        }
      }

      assert {:error, %ServerError{}} = GoogleGemini.decode_response(body)
    end

    test "decodes 503 error as ServerError" do
      body = %{
        "error" => %{
          "code" => 503,
          "message" => "Service unavailable",
          "status" => "UNAVAILABLE"
        }
      }

      assert {:error, %ServerError{}} = GoogleGemini.decode_response(body)
    end

    test "decodes other errors as ResponseInvalid" do
      body = %{
        "error" => %{
          "code" => 400,
          "message" => "Bad request",
          "status" => "INVALID_ARGUMENT"
        }
      }

      assert {:error, %ResponseInvalid{}} = GoogleGemini.decode_response(body)
    end

    test "returns error for unexpected body shape" do
      body = %{"unexpected" => "shape"}
      assert {:error, %ResponseInvalid{}} = GoogleGemini.decode_response(body)
    end
  end

  describe "init_stream/0" do
    test "returns a StreamState struct" do
      state = GoogleGemini.init_stream()

      assert %{
               text: "",
               tool_calls: %{},
               thinking: "",
               usage: nil,
               model: nil
             } = state
    end
  end

  describe "decode_stream_chunk/2" do
    test "full text streaming lifecycle" do
      state = GoogleGemini.init_stream()

      event1 = %{
        data: %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "Hello"}], "role" => "model"}}
          ],
          "modelVersion" => "gemini-2.0-flash"
        }
      }

      assert {:ok, state, [chunk]} = GoogleGemini.decode_stream_chunk(state, event1)
      assert %StreamChunk{type: :text_delta, data: "Hello"} = chunk
      assert state.model == "gemini-2.0-flash"

      event2 = %{
        data: %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => " world"}], "role" => "model"}}
          ]
        }
      }

      assert {:ok, state, [chunk]} = GoogleGemini.decode_stream_chunk(state, event2)
      assert chunk.data == " world"
      assert state.text == "Hello world"

      event3 = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "!"}], "role" => "model"},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 15,
            "totalTokenCount" => 25
          }
        }
      }

      assert {:done, %Response{} = response, [chunk]} =
               GoogleGemini.decode_stream_chunk(state, event3)

      assert chunk.type == :text_delta
      assert chunk.data == "!"
      assert response.text == "Hello world!"
      assert response.model == "gemini-2.0-flash"
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 15
    end

    test "streaming with tool calls" do
      state = GoogleGemini.init_stream()

      event = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"functionCall" => %{"name" => "weather", "args" => %{"city" => "Paris"}}}
                ],
                "role" => "model"
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 5,
            "candidatesTokenCount" => 10,
            "totalTokenCount" => 15
          },
          "modelVersion" => "gemini-2.0-flash"
        }
      }

      assert {:done, %Response{} = response, _chunks} =
               GoogleGemini.decode_stream_chunk(state, event)

      assert [tc] = response.tool_calls
      assert tc.name == "weather"
      assert tc.arguments == %{"city" => "Paris"}
    end

    test "streaming with thinking" do
      state = GoogleGemini.init_stream()

      event1 = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "Let me think...", "thought" => true}],
                "role" => "model"
              }
            }
          ],
          "modelVersion" => "gemini-2.0-flash"
        }
      }

      assert {:ok, state, [chunk]} = GoogleGemini.decode_stream_chunk(state, event1)
      assert %StreamChunk{type: :reasoning_delta, data: "Let me think..."} = chunk
      assert state.thinking == "Let me think..."

      event2 = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "The answer is 42"}],
                "role" => "model"
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 20,
            "totalTokenCount" => 30
          }
        }
      }

      assert {:done, %Response{} = response, _chunks} =
               GoogleGemini.decode_stream_chunk(state, event2)

      assert response.text == "The answer is 42"
      assert response.reasoning == %Reasoning{summary: "Let me think..."}
    end

    test "skips unknown events" do
      state = GoogleGemini.init_stream()
      event = %{event: "ping", data: %{}}
      assert {:ok, ^state, []} = GoogleGemini.decode_stream_chunk(state, event)
    end

    test "handles MAX_TOKENS finish reason" do
      state = GoogleGemini.init_stream()

      event = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "truncated"}], "role" => "model"},
              "finishReason" => "MAX_TOKENS"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 5,
            "candidatesTokenCount" => 100,
            "totalTokenCount" => 105
          }
        }
      }

      assert {:done, %Response{}, _chunks} = GoogleGemini.decode_stream_chunk(state, event)
    end
  end

  # --- Helpers ---

  defp build_request(messages, opts \\ []) do
    %Request{
      messages: messages,
      model: opts[:model] || "gemini-2.0-flash",
      params: opts[:params],
      tools: opts[:tools] || [],
      response_schema: opts[:response_schema],
      stream: opts[:stream],
      provider_params: opts[:provider_params] || %{}
    }
  end

  defp gemini_response(opts) do
    parts = Keyword.fetch!(opts, :parts)

    usage =
      Keyword.get(opts, :usage, %{
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 100,
        "totalTokenCount" => 110
      })

    %{
      "candidates" => [
        %{
          "content" => %{"parts" => parts, "role" => "model"},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => usage,
      "modelVersion" => "gemini-2.0-flash"
    }
  end
end
