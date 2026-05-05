defmodule Sycophant.WireProtocol.CopilotChatTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message
  alias Sycophant.Message.Content.Thinking
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.StreamChunk
  alias Sycophant.WireProtocol.CopilotChat

  describe "delegation to OpenAICompletions" do
    test "request_path is /chat/completions" do
      request = build_request([Message.user("hi")])
      assert CopilotChat.request_path(request) == "/chat/completions"
    end

    test "stream_transport is :sse" do
      assert CopilotChat.stream_transport() == :sse
    end

    test "encode_request produces an OpenAI-Chat-shaped payload" do
      request = build_request([Message.user("hello")])
      assert {:ok, payload} = CopilotChat.encode_request(request)
      assert payload["model"] == "github_copilot:gpt-4o"
      assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    end
  end

  describe "decode_response/1" do
    test "captures reasoning_text into Reasoning.content" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "Sure! Paris is sunny.",
              "reasoning_text" => "The user wants weather in Paris.",
              "reasoning_opaque" => "abc123opaque"
            }
          }
        ],
        "model" => "gpt-4o",
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      assert {:ok, response} = CopilotChat.decode_response(body)
      assert response.text == "Sure! Paris is sunny."

      assert %Reasoning{
               content: [%Thinking{text: "The user wants weather in Paris."}],
               encrypted_content: "abc123opaque"
             } = response.reasoning
    end

    test "captures reasoning_opaque alone when reasoning_text is absent" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "ok",
              "reasoning_opaque" => "blob"
            }
          }
        ],
        "model" => "gpt-4o",
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      }

      assert {:ok, response} = CopilotChat.decode_response(body)
      assert %Reasoning{content: [], encrypted_content: "blob"} = response.reasoning
    end

    test "leaves reasoning nil when neither field is present" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "hi"}
          }
        ],
        "model" => "gpt-4o",
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      }

      assert {:ok, response} = CopilotChat.decode_response(body)
      assert response.reasoning == nil
    end

    test "decodes tool_calls alongside content" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{"name" => "get_weather", "arguments" => "{\"city\":\"Paris\"}"}
                }
              ]
            }
          }
        ],
        "model" => "gpt-4o",
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      assert {:ok, response} = CopilotChat.decode_response(body)
      assert [%{name: "get_weather", arguments: %{"city" => "Paris"}}] = response.tool_calls
      assert response.finish_reason == :tool_use
    end
  end

  describe "decode_stream_chunk/2 - reasoning fragments" do
    test "emits :reasoning_delta chunk when delta has reasoning_text and content is null" do
      state = CopilotChat.init_stream()

      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "role" => "assistant",
                "content" => nil,
                "reasoning_text" => "Thinking step one. "
              }
            }
          ]
        }
      }

      assert {:ok, state, [chunk]} = CopilotChat.decode_stream_chunk(state, event)
      assert chunk == %StreamChunk{type: :reasoning_delta, data: "Thinking step one. "}
      assert state.reasoning_text == "Thinking step one. "
    end

    test "accumulates multiple reasoning_text fragments" do
      state = CopilotChat.init_stream()

      e1 = stream_event(%{"reasoning_text" => "A. "})
      e2 = stream_event(%{"reasoning_text" => "B."})

      {:ok, state, _} = CopilotChat.decode_stream_chunk(state, e1)
      {:ok, state, _} = CopilotChat.decode_stream_chunk(state, e2)

      assert state.reasoning_text == "A. B."
    end
  end

  describe "decode_stream_chunk/2 - packed final chunk" do
    test "emits text_delta chunks alongside :done when content and finish_reason arrive together" do
      state = CopilotChat.init_stream()

      event = %{
        data: %{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "delta" => %{"content" => "hello", "role" => "assistant"}
            }
          ],
          "model" => "gemini-2.5-pro"
        }
      }

      assert {:done, response, [chunk]} = CopilotChat.decode_stream_chunk(state, event)
      assert chunk == %StreamChunk{type: :text_delta, data: "hello"}
      assert response.text == "hello"
      assert response.finish_reason == :stop
      assert response.model == "gemini-2.5-pro"
    end

    test "builds reasoning into the final response when reasoning fragments preceded the final chunk" do
      state = CopilotChat.init_stream()

      {:ok, state, _} =
        CopilotChat.decode_stream_chunk(
          state,
          stream_event(%{"reasoning_text" => "Reasoning A. "})
        )

      {:ok, state, _} =
        CopilotChat.decode_stream_chunk(
          state,
          stream_event(%{"reasoning_text" => "Reasoning B."})
        )

      final = %{
        data: %{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "delta" => %{"content" => "Final answer.", "role" => "assistant"}
            }
          ]
        }
      }

      assert {:done, response, [text_chunk]} = CopilotChat.decode_stream_chunk(state, final)
      assert text_chunk == %StreamChunk{type: :text_delta, data: "Final answer."}

      assert %Reasoning{content: [%Thinking{text: "Reasoning A. Reasoning B."}]} =
               response.reasoning
    end
  end

  defp build_request(messages) do
    %Request{
      messages: messages,
      model: "github_copilot:gpt-4o",
      params: %{},
      tools: [],
      stream: nil,
      response_schema: nil
    }
  end

  defp stream_event(delta) do
    %{
      data: %{
        "choices" => [
          %{
            "delta" => Map.merge(%{"role" => "assistant", "content" => nil}, delta)
          }
        ]
      }
    }
  end
end
