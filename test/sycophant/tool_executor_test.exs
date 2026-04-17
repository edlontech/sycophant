defmodule Sycophant.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Response
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.ToolExecutor

  defp build_response(attrs) do
    defaults = %{
      text: nil,
      tool_calls: [],
      context: %Context{
        messages: [Message.user("Hi")]
      }
    }

    struct(Response, Map.merge(defaults, attrs))
  end

  defp build_tool(name, function \\ nil) do
    %Tool{
      name: name,
      description: "A test tool",
      parameters: %{},
      schema_source: nil,
      resolved_schema: nil,
      function: function
    }
  end

  defp build_tool_with_schema(name, zoi_schema, function) do
    resolved =
      case Sycophant.Schema.Normalizer.normalize(zoi_schema) do
        {:ok, normalized} -> normalized
        _ -> nil
      end

    %Tool{
      name: name,
      description: "A test tool",
      parameters: zoi_schema,
      schema_source: :zoi,
      resolved_schema: resolved,
      function: function
    }
  end

  describe "run/4" do
    test "returns response immediately when no tool_calls" do
      response = build_response(%{text: "Hello!", tool_calls: []})
      tools = [build_tool("weather", fn _args -> "sunny" end)]

      call_fn = fn _msgs -> flunk("call_fn should not be called") end

      assert {:ok, ^response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "returns response when tool_calls present but no tools have functions" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}
      response = build_response(%{tool_calls: [tool_call]})
      tools = [build_tool("weather")]

      call_fn = fn _msgs -> flunk("call_fn should not be called") end

      assert {:ok, ^response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "executes tool function and re-submits with correct messages" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("What's the weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "It's sunny in Paris!", tool_calls: []})

      tool =
        build_tool_with_schema(
          "weather",
          Zoi.object(%{city: Zoi.string()}),
          fn %{city: city} -> "Sunny in #{city}" end
        )

      call_fn = fn messages ->
        assert length(messages) == 3
        assert Enum.at(messages, 0).role == :user
        assert Enum.at(messages, 1).role == :assistant
        assert Enum.at(messages, 1).tool_calls == [tool_call]

        tool_result_msg = Enum.at(messages, 2)
        assert tool_result_msg.role == :tool_result
        assert tool_result_msg.tool_call_id == "call_1"
        assert tool_result_msg.content == "Sunny in Paris"

        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, [tool], [], call_fn)
    end

    test "catches exceptions and sends error as tool result" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("weather"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "Sorry, error", tool_calls: []})

      tools = [build_tool("weather", fn _args -> raise "kaboom" end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.role == :tool_result
        assert tool_result_msg.content =~ "kaboom"

        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "loops multiple times until no tool_calls" do
      counter = :counters.new(1, [:atomics])

      tool_call_1 = %ToolCall{id: "call_1", name: "step", arguments: %{"n" => 1}}
      tool_call_2 = %ToolCall{id: "call_2", name: "step", arguments: %{"n" => 2}}

      initial_response =
        build_response(%{
          tool_calls: [tool_call_1],
          context: %Context{
            messages: [
              Message.user("go"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call_1]}
            ]
          }
        })

      second_response =
        build_response(%{
          tool_calls: [tool_call_2],
          context: %Context{
            messages: [
              Message.user("go"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call_1]},
              Message.tool_result(tool_call_1, "done 1"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call_2]}
            ]
          }
        })

      final_response = build_response(%{text: "All done!", tool_calls: []})

      tools = [build_tool("step", fn %{"n" => n} -> "done #{n}" end)]

      call_fn = fn _messages ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        case count do
          1 -> {:ok, second_response}
          2 -> {:ok, final_response}
        end
      end

      assert {:ok, ^final_response} = ToolExecutor.run(initial_response, tools, [], call_fn)
      assert :counters.get(counter, 1) == 2
    end

    test "respects max_steps limit" do
      counter = :counters.new(1, [:atomics])

      make_response = fn id ->
        tc = %ToolCall{id: "call_#{id}", name: "step", arguments: %{}}

        build_response(%{
          tool_calls: [tc],
          context: %Context{
            messages: [
              Message.user("go"),
              %Message{role: :assistant, content: nil, tool_calls: [tc]}
            ]
          }
        })
      end

      initial_response = make_response.(1)
      tools = [build_tool("step", fn _args -> "ok" end)]

      call_fn = fn _messages ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)
        {:ok, make_response.(count + 1)}
      end

      assert {:ok, result} = ToolExecutor.run(initial_response, tools, [max_steps: 3], call_fn)
      assert result.tool_calls != []
      assert :counters.get(counter, 1) == 3
    end

    test "propagates errors from call_fn" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("weather"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      tools = [build_tool("weather", fn _args -> "sunny" end)]

      call_fn = fn _messages ->
        {:error, %RuntimeError{message: "transport failed"}}
      end

      assert {:error, %RuntimeError{message: "transport failed"}} =
               ToolExecutor.run(response, tools, [], call_fn)
    end

    test "returns error string for unmatched tool calls" do
      tool_call = %ToolCall{id: "call_1", name: "unknown_tool", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("test"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})

      tools = [build_tool("weather", fn _args -> "sunny" end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.role == :tool_result
        assert tool_result_msg.content =~ "unknown_tool"

        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "tool with Zoi schema receives atom keys in function" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("What's the weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "Done", tool_calls: []})

      tool =
        build_tool_with_schema(
          "weather",
          Zoi.object(%{city: Zoi.string()}),
          fn %{city: city} -> "Sunny in #{city}" end
        )

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.content == "Sunny in Paris"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, [tool], [], call_fn)
    end

    test "tool with resolved_schema=nil still works (backward compat)" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("Weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "Done", tool_calls: []})

      tool = %Tool{
        name: "weather",
        description: "Get weather",
        parameters: %{},
        function: fn %{"city" => city} -> "Sunny in #{city}" end,
        schema_source: nil,
        resolved_schema: nil
      }

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.content == "Sunny in Paris"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, [tool], [], call_fn)
    end

    test "tool with JSON Schema source receives string keys in function" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("What's the weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "Done", tool_calls: []})

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"}
        },
        "required" => ["city"]
      }

      {:ok, resolved} = Sycophant.Schema.Normalizer.normalize(json_schema)

      tool = %Tool{
        name: "weather",
        description: "Get weather",
        parameters: json_schema,
        schema_source: :json_schema,
        resolved_schema: resolved,
        function: fn %{"city" => city} -> "Sunny in #{city}" end
      }

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.content == "Sunny in Paris"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, [tool], [], call_fn)
    end

    test "coerces map return value to JSON string" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "Paris"}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("Weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})
      tools = [build_tool("weather", fn _args -> %{temp: 72, cond: "sunny"} end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert is_binary(tool_result_msg.content)
        assert {:ok, %{"temp" => 72, "cond" => "sunny"}} = JSON.decode(tool_result_msg.content)
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "coerces list return value to JSON string" do
      tool_call = %ToolCall{id: "call_1", name: "list", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("list"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})
      tools = [build_tool("list", fn _args -> [1, 2, 3] end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.content == "[1,2,3]"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "coerces tuple return value via inspect" do
      tool_call = %ToolCall{id: "call_1", name: "pair", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("pair"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})
      tools = [build_tool("pair", fn _args -> {1, 2} end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.content == "{1, 2}"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "unwraps {:ok, value} return convention" do
      tool_call = %ToolCall{id: "call_1", name: "fetch", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("fetch"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})
      tools = [build_tool("fetch", fn _args -> {:ok, %{id: 1}} end)]

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert {:ok, %{"id" => 1}} = JSON.decode(tool_result_msg.content)
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "stringifies {:error, reason} return convention" do
      tc1 = %ToolCall{id: "c1", name: "fail_atom", arguments: %{}}
      tc2 = %ToolCall{id: "c2", name: "fail_str", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tc1, tc2],
          context: %Context{
            messages: [
              Message.user("go"),
              %Message{role: :assistant, content: nil, tool_calls: [tc1, tc2]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})

      tools = [
        build_tool("fail_atom", fn _ -> {:error, :not_found} end),
        build_tool("fail_str", fn _ -> {:error, "db down"} end)
      ]

      call_fn = fn messages ->
        [_user, _assistant, a, b] = messages
        assert a.content == "Error: :not_found"
        assert b.content == "Error: db down"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "coerces atom and number return values to strings" do
      tc1 = %ToolCall{id: "c1", name: "atom_t", arguments: %{}}
      tc2 = %ToolCall{id: "c2", name: "num_t", arguments: %{}}

      response =
        build_response(%{
          tool_calls: [tc1, tc2],
          context: %Context{
            messages: [
              Message.user("go"),
              %Message{role: :assistant, content: nil, tool_calls: [tc1, tc2]}
            ]
          }
        })

      final_response = build_response(%{text: "ok", tool_calls: []})

      tools = [
        build_tool("atom_t", fn _ -> :ok end),
        build_tool("num_t", fn _ -> 42 end)
      ]

      call_fn = fn messages ->
        [_user, _assistant, atom_msg, num_msg] = messages
        assert atom_msg.content == "ok"
        assert num_msg.content == "42"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, tools, [], call_fn)
    end

    test "validation failure returns error string as tool result" do
      tool_call = %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => 123}}

      response =
        build_response(%{
          tool_calls: [tool_call],
          context: %Context{
            messages: [
              Message.user("Weather?"),
              %Message{role: :assistant, content: nil, tool_calls: [tool_call]}
            ]
          }
        })

      final_response = build_response(%{text: "Sorry", tool_calls: []})

      tool =
        build_tool_with_schema(
          "weather",
          Zoi.object(%{city: Zoi.string()}),
          fn %{city: city} -> "Sunny in #{city}" end
        )

      call_fn = fn messages ->
        tool_result_msg = List.last(messages)
        assert tool_result_msg.role == :tool_result
        assert tool_result_msg.content =~ "Validation error"
        {:ok, final_response}
      end

      assert {:ok, ^final_response} = ToolExecutor.run(response, [tool], [], call_fn)
    end
  end
end
