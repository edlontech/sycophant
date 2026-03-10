defmodule Sycophant.ContextTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Tool

  describe "new/0" do
    test "creates an empty context" do
      ctx = Context.new()
      assert %Context{messages: [], params: %{}, tools: []} = ctx
      assert ctx.stream == nil
    end
  end

  describe "new/1 with opts" do
    test "creates a context with tools" do
      tool = %Tool{name: "t", description: "d", parameters: %{}}
      ctx = Context.new(tools: [tool])
      assert ctx.tools == [tool]
      assert ctx.messages == []
    end

    test "creates a context with params" do
      ctx = Context.new(temperature: 0.5)
      assert ctx.params == %{temperature: 0.5}
    end

    test "creates a context with a stream callback" do
      cb = fn chunk -> chunk end
      ctx = Context.new(stream: cb)
      assert ctx.stream == cb
    end
  end

  describe "new/1 with messages" do
    test "creates a context with a message list" do
      msgs = [Message.user("hello")]
      ctx = Context.new(msgs)
      assert ctx.messages == msgs
      assert ctx.tools == []
    end
  end

  describe "new/2" do
    test "creates a context with messages and opts" do
      msgs = [Message.system("sys"), Message.user("hi")]
      tool = %Tool{name: "t", description: "d", parameters: %{}}
      ctx = Context.new(msgs, tools: [tool], temperature: 1.0)

      assert ctx.messages == msgs
      assert ctx.tools == [tool]
      assert ctx.params == %{temperature: 1.0}
    end
  end

  describe "add/2" do
    test "appends a single message" do
      ctx = Context.add(Context.new(), Message.user("hello"))
      assert [%Message{role: :user, content: "hello"}] = ctx.messages
    end

    test "appends a list of messages" do
      msgs = [Message.user("a"), Message.assistant("b")]
      ctx = Context.add(Context.new(), msgs)
      assert length(ctx.messages) == 2
    end

    test "preserves existing messages" do
      ctx =
        Context.new([Message.system("sys")])
        |> Context.add(Message.user("hello"))

      assert [%Message{role: :system}, %Message{role: :user}] = ctx.messages
    end
  end

  describe "to_opts/1" do
    test "returns empty list for default context" do
      assert Context.to_opts(Context.new()) == []
    end

    test "includes tools when present" do
      tool = %Tool{name: "t", description: "d", parameters: %{}}
      opts = Context.new(tools: [tool]) |> Context.to_opts()
      assert opts[:tools] == [tool]
    end

    test "includes stream when present" do
      cb = fn chunk -> chunk end
      opts = Context.new(stream: cb) |> Context.to_opts()
      assert opts[:stream] == cb
    end

    test "flattens params to top-level opts" do
      opts = Context.new([], temperature: 0.7) |> Context.to_opts()
      assert opts[:temperature] == 0.7
    end

    test "omits nil and empty values" do
      opts = Context.new(tools: []) |> Context.to_opts()
      assert opts == []
    end
  end

  describe "struct no longer has model or response_schema" do
    test "model field does not exist" do
      ctx = Context.new()
      refute Map.has_key?(ctx, :model)
    end

    test "response_schema field does not exist" do
      ctx = Context.new()
      refute Map.has_key?(ctx, :response_schema)
    end
  end

  describe "serialization round-trip" do
    test "to_map excludes model and response_schema" do
      ctx = Context.new([Message.user("hi")])
      map = Sycophant.Serializable.to_map(ctx)
      refute Map.has_key?(map, "model")
      refute Map.has_key?(map, "response_schema")
      assert map["__type__"] == "Context"
    end

    test "from_map ignores model and response_schema in input" do
      map = %{
        "messages" => [%{"__type__" => "Message", "role" => "user", "content" => "hi"}],
        "model" => "should-be-ignored",
        "response_schema" => %{"type" => "object"}
      }

      ctx = Context.from_map(map)
      refute Map.has_key?(ctx, :model)
      refute Map.has_key?(ctx, :response_schema)
      assert [%Message{role: :user, content: "hi"}] = ctx.messages
    end
  end
end
