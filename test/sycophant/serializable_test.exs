defmodule Sycophant.SerializableTest do
  use ExUnit.Case, async: true

  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder

  describe "Content.Text" do
    test "round-trips through JSON" do
      original = %Sycophant.Message.Content.Text{text: "hello"}
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "includes type discriminators" do
      map = Serializable.to_map(%Sycophant.Message.Content.Text{text: "hello"})
      assert map["__type__"] == "Text"
      assert map["type"] == "text"
    end
  end

  describe "Content.Image" do
    test "round-trips with url" do
      original = %Sycophant.Message.Content.Image{
        url: "https://example.com/img.png",
        media_type: "image/png"
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "round-trips with base64 data" do
      original = %Sycophant.Message.Content.Image{data: "base64data", media_type: "image/jpeg"}
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "compacts nil fields" do
      map = Serializable.to_map(%Sycophant.Message.Content.Image{url: "http://x.com/i.png"})
      refute Map.has_key?(map, "data")
      refute Map.has_key?(map, "media_type")
    end
  end

  describe "ToolCall" do
    test "round-trips through JSON" do
      original = %Sycophant.ToolCall{
        id: "call_1",
        name: "get_weather",
        arguments: %{"city" => "NYC"}
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end
  end

  describe "Usage" do
    test "round-trips through JSON" do
      original = %Sycophant.Usage{input_tokens: 100, output_tokens: 50}
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "compacts nil fields" do
      map = Serializable.to_map(%Sycophant.Usage{input_tokens: 100, output_tokens: 50})
      refute Map.has_key?(map, "cache_creation_input_tokens")
    end
  end

  describe "Reasoning" do
    test "round-trips through JSON" do
      original = %Sycophant.Reasoning{summary: "thought about it", encrypted_content: "enc123"}
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "compacts nil fields" do
      map = Serializable.to_map(%Sycophant.Reasoning{summary: "hi"})
      refute Map.has_key?(map, "encrypted_content")
    end
  end

  describe "Params" do
    test "round-trips with atom enum fields" do
      original = %Sycophant.Params{
        temperature: 0.7,
        max_tokens: 1000,
        reasoning: :high,
        reasoning_summary: :concise,
        stop: ["END"]
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "handles nil fields" do
      original = %Sycophant.Params{temperature: 0.5}
      decoded = original |> Decoder.encode() |> Decoder.decode()
      assert decoded.temperature == 0.5
      assert decoded.max_tokens == nil
    end

    test "compacts nil fields from serialized map" do
      map = Serializable.to_map(%Sycophant.Params{temperature: 0.5})
      assert map["__type__"] == "Params"
      assert map["temperature"] == 0.5
      refute Map.has_key?(map, "max_tokens")
      refute Map.has_key?(map, "reasoning")
    end
  end

  describe "Tool" do
    test "round-trips with parameters as JSON Schema" do
      original = %Sycophant.Tool{
        name: "get_weather",
        description: "Gets weather",
        parameters: Zoi.map(%{city: Zoi.string()}),
        function: &String.upcase/1
      }

      decoded = original |> Decoder.encode() |> Decoder.decode()
      assert decoded.name == "get_weather"
      assert decoded.description == "Gets weather"
      assert is_map(decoded.parameters)
      assert decoded.parameters["type"] == "object"
      assert decoded.function == nil
    end

    test "re-attaches function from tool registry" do
      original = %Sycophant.Tool{
        name: "search",
        description: "Searches",
        parameters: Zoi.map(%{q: Zoi.string()}),
        function: &String.upcase/1
      }

      fun = fn args -> "result: #{args["q"]}" end
      json = Decoder.encode(original)
      decoded = Decoder.decode(json, tool_registry: %{"search" => fun})
      assert decoded.function == fun
    end
  end

  describe "Message" do
    test "round-trips text message" do
      original = Sycophant.Message.user("hello world")
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "round-trips multimodal message" do
      original = %Sycophant.Message{
        role: :user,
        content: [
          %Sycophant.Message.Content.Text{text: "describe this"},
          %Sycophant.Message.Content.Image{
            url: "https://example.com/img.png",
            media_type: "image/png"
          }
        ]
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "round-trips assistant message with tool calls" do
      original = %Sycophant.Message{
        role: :assistant,
        content: "I'll look that up",
        tool_calls: [
          %Sycophant.ToolCall{id: "c1", name: "search", arguments: %{"q" => "elixir"}}
        ]
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "round-trips tool_result with metadata" do
      tc = %Sycophant.ToolCall{id: "c1", name: "search", arguments: %{}}
      original = Sycophant.Message.tool_result(tc, "found it")
      assert original == original |> Decoder.encode() |> Decoder.decode()
    end

    test "preserves wire_protocol" do
      original = %Sycophant.Message{
        role: :user,
        content: "hi",
        wire_protocol: :anthropic_messages
      }

      assert original == original |> Decoder.encode() |> Decoder.decode()
    end
  end

  describe "Context" do
    test "round-trips with messages and tools" do
      ctx = %Sycophant.Context{
        messages: [Sycophant.Message.user("hi"), Sycophant.Message.assistant("hello")],
        model: "claude-sonnet-4-20250514",
        params: %Sycophant.Params{temperature: 0.7},
        tools: [
          %Sycophant.Tool{
            name: "search",
            description: "Search",
            parameters: Zoi.map(%{q: Zoi.string()})
          }
        ]
      }

      decoded = ctx |> Decoder.encode() |> Decoder.decode()
      assert length(decoded.messages) == 2
      assert decoded.model == ctx.model
      assert decoded.params.temperature == 0.7
      assert length(decoded.tools) == 1
      assert decoded.stream == nil
    end

    test "drops stream function" do
      ctx = %Sycophant.Context{
        messages: [Sycophant.Message.user("hi")],
        stream: fn chunk -> IO.puts(chunk) end
      }

      map = Serializable.to_map(ctx)
      refute Map.has_key?(map, "stream")
    end

    test "converts response_schema to JSON Schema" do
      schema = Zoi.map(%{name: Zoi.string()})

      ctx = %Sycophant.Context{
        messages: [Sycophant.Message.user("hi")],
        response_schema: schema
      }

      map = Serializable.to_map(ctx)
      assert map["response_schema"]["type"] == "object"
    end

    test "compacts empty provider_params and tools" do
      ctx = %Sycophant.Context{
        messages: [Sycophant.Message.user("hi")],
        model: "test-model"
      }

      map = Serializable.to_map(ctx)
      refute Map.has_key?(map, "provider_params")
      refute Map.has_key?(map, "tools")
    end
  end

  describe "Response" do
    test "full round-trip" do
      response = %Sycophant.Response{
        text: "Hello there",
        model: "claude-sonnet-4-20250514",
        usage: %Sycophant.Usage{input_tokens: 10, output_tokens: 20},
        reasoning: %Sycophant.Reasoning{summary: "thought about it"},
        tool_calls: [],
        context: %Sycophant.Context{
          messages: [
            Sycophant.Message.user("hi"),
            Sycophant.Message.assistant("Hello there")
          ],
          model: "claude-sonnet-4-20250514"
        }
      }

      decoded = response |> Decoder.encode() |> Decoder.decode()
      assert decoded.text == "Hello there"
      assert decoded.usage.input_tokens == 10
      assert decoded.reasoning.summary == "thought about it"
      assert length(decoded.context.messages) == 2
    end

    test "round-trips finish_reason" do
      response = %Sycophant.Response{
        text: "Hello",
        finish_reason: :stop,
        context: %Sycophant.Context{
          messages: [Sycophant.Message.user("hi")],
          model: "test-model"
        }
      }

      decoded = response |> Decoder.encode() |> Decoder.decode()
      assert decoded.finish_reason == :stop
    end

    test "serializes finish_reason as string" do
      response = %Sycophant.Response{
        text: "Hello",
        finish_reason: :tool_use,
        context: %Sycophant.Context{
          messages: [Sycophant.Message.user("hi")]
        }
      }

      map = Serializable.to_map(response)
      assert map["finish_reason"] == "tool_use"
    end

    test "omits finish_reason when nil" do
      response = %Sycophant.Response{
        text: "Hello",
        context: %Sycophant.Context{
          messages: [Sycophant.Message.user("hi")]
        }
      }

      map = Serializable.to_map(response)
      refute Map.has_key?(map, "finish_reason")
    end

    test "compacts empty tool_calls" do
      response = %Sycophant.Response{
        text: "hi",
        tool_calls: [],
        context: %Sycophant.Context{
          messages: [Sycophant.Message.user("hi")]
        }
      }

      map = Serializable.to_map(response)
      refute Map.has_key?(map, "tool_calls")
    end
  end

  describe "Decoder error handling" do
    alias Sycophant.Error.Invalid.InvalidSerialization

    test "raises for unknown __type__" do
      assert_raise InvalidSerialization, ~r/unknown serializable type: "Bogus"/, fn ->
        Decoder.from_map(%{"__type__" => "Bogus"})
      end
    end

    test "raises for missing __type__" do
      assert_raise InvalidSerialization, ~r/missing __type__ key/, fn ->
        Decoder.from_map(%{"foo" => "bar"})
      end
    end
  end
end
