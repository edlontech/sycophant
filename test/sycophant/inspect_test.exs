defmodule Sycophant.InspectTest do
  use ExUnit.Case, async: true

  describe "Usage" do
    test "shows compact token format" do
      usage = %Sycophant.Usage{input_tokens: 150, output_tokens: 42, total_cost: 0.0023}
      result = inspect(usage)
      assert result =~ "#Sycophant.Usage<"
      assert result =~ "in: 150"
      assert result =~ "out: 42"
      assert result =~ "cost: 0.0023"
    end

    test "omits nil fields" do
      usage = %Sycophant.Usage{input_tokens: 10, output_tokens: 5}
      result = inspect(usage)
      refute result =~ "cost:"
    end
  end

  describe "Reasoning" do
    test "truncates content text and redacts encrypted content" do
      reasoning = %Sycophant.Reasoning{
        content: [
          %Sycophant.Message.Content.Thinking{text: String.duplicate("a", 60)}
        ],
        encrypted_content: "secret-data"
      }

      result = inspect(reasoning)
      assert result =~ "#Sycophant.Reasoning<"
      assert result =~ "..."
      assert result =~ "**REDACTED**"
    end

    test "omits nil encrypted_content" do
      reasoning = %Sycophant.Reasoning{
        content: [%Sycophant.Message.Content.Thinking{text: "short"}]
      }

      result = inspect(reasoning)
      refute result =~ "encrypted_content"
    end
  end

  describe "ToolCall" do
    test "shows id, name, and truncated arguments" do
      tc = %Sycophant.ToolCall{
        id: "toolu_01XFDabcdefghijk",
        name: "calculator",
        arguments: %{expression: "2+2"}
      }

      result = inspect(tc)
      assert result =~ "#Sycophant.ToolCall<"
      assert result =~ "calculator"
    end
  end

  describe "StreamChunk" do
    test "shows type and truncated data" do
      chunk = %Sycophant.StreamChunk{type: :text_delta, data: "Hello"}
      result = inspect(chunk)
      assert result =~ "#Sycophant.StreamChunk<"
      assert result =~ ":text_delta"
    end
  end

  describe "Content.Text" do
    test "shows truncated text" do
      text = %Sycophant.Message.Content.Text{text: String.duplicate("x", 60)}
      result = inspect(text)
      assert result =~ "#Sycophant.Message.Content.Text<"
      assert result =~ "..."
    end
  end

  describe "Content.Image" do
    test "redacts base64 data" do
      img = %Sycophant.Message.Content.Image{data: "iVBORw0KGgo...", media_type: "image/png"}
      result = inspect(img)
      assert result =~ "#Sycophant.Message.Content.Image<"
      assert result =~ "**REDACTED**"
      refute result =~ "iVBORw0KGgo"
    end

    test "shows url when present" do
      img = %Sycophant.Message.Content.Image{url: "https://example.com/photo.jpg"}
      result = inspect(img)
      assert result =~ "https://example.com/photo.jpg"
    end
  end

  describe "Tool" do
    test "shows name and function label" do
      tool = %Sycophant.Tool{
        name: "calc",
        description: "Calculator",
        parameters: %{},
        function: fn _x -> "ok" end
      }

      result = inspect(tool)
      assert result =~ "#Sycophant.Tool<"
      assert result =~ "calc"
      assert result =~ "fn/1"
    end

    test "omits nil function" do
      tool = %Sycophant.Tool{name: "search", description: "Search", parameters: %{}}
      result = inspect(tool)
      refute result =~ "function"
    end
  end

  describe "Message" do
    test "shows role and truncated string content" do
      msg = Sycophant.Message.user(String.duplicate("x", 60))
      result = inspect(msg)
      assert result =~ "#Sycophant.Message<"
      assert result =~ ":user"
      assert result =~ "..."
    end

    test "shows part count for multimodal content" do
      msg =
        Sycophant.Message.user([
          %Sycophant.Message.Content.Text{text: "hello"},
          %Sycophant.Message.Content.Image{url: "https://example.com/img.jpg"}
        ])

      result = inspect(msg)
      assert result =~ "2 parts"
    end

    test "shows tool_call_id for tool results" do
      tc = %Sycophant.ToolCall{id: "call_123", name: "calc", arguments: %{}}
      msg = Sycophant.Message.tool_result(tc, "42")
      result = inspect(msg)
      assert result =~ "call_123"
    end
  end

  describe "Config.Provider" do
    test "redacts sensitive fields" do
      provider = %Sycophant.Config.Provider{
        api_key: "sk-secret-key",
        region: "us-east-1",
        base_url: "https://api.example.com"
      }

      result = inspect(provider)
      assert result =~ "#Sycophant.Config.Provider<"
      assert result =~ "**REDACTED**"
      refute result =~ "sk-secret-key"
      assert result =~ "us-east-1"
    end

    test "omits nil fields" do
      provider = %Sycophant.Config.Provider{api_key: "key"}
      result = inspect(provider)
      refute result =~ "region"
      refute result =~ "base_url"
    end
  end

  describe "Context" do
    test "shows message and tool counts" do
      ctx = %Sycophant.Context{
        messages: [Sycophant.Message.user("hi"), Sycophant.Message.assistant("hello")],
        tools: [%Sycophant.Tool{name: "t", description: "d", parameters: %{}}]
      }

      result = inspect(ctx)
      assert result =~ "#Sycophant.Context<"
      assert result =~ "messages: 2"
      assert result =~ "tools: 1"
    end

    test "shows stream function label" do
      ctx = %Sycophant.Context{stream: fn _x -> :ok end}
      result = inspect(ctx)
      assert result =~ "fn/1"
    end

    test "omits zero counts" do
      ctx = %Sycophant.Context{}
      result = inspect(ctx)
      refute result =~ "messages:"
      refute result =~ "tools:"
    end
  end

  describe "Request" do
    test "shows model and message count" do
      req = %Sycophant.Request{
        model: "anthropic:claude-haiku-4-5-20251001",
        messages: [Sycophant.Message.user("hi")]
      }

      result = inspect(req)
      assert result =~ "#Sycophant.Request<"
      assert result =~ "anthropic:claude-haiku-4-5-20251001"
      assert result =~ "messages: 1"
    end

    test "redacts credentials" do
      req = %Sycophant.Request{
        model: "m",
        messages: [],
        credentials: %{api_key: "secret"}
      }

      result = inspect(req)
      assert result =~ "**REDACTED**"
      refute result =~ "secret"
    end
  end

  describe "EmbeddingParams" do
    test "shows non-nil fields" do
      params = %Sycophant.EmbeddingParams{
        dimensions: 256,
        embedding_types: [:float, :int8],
        truncate: :none
      }

      result = inspect(params)
      assert result =~ "#Sycophant.EmbeddingParams<"
      assert result =~ "256"
      assert result =~ ":float"
    end
  end

  describe "EmbeddingRequest" do
    test "shows model and input count" do
      req = %Sycophant.EmbeddingRequest{model: "cohere:embed-v3", inputs: ["hello", "world"]}
      result = inspect(req)
      assert result =~ "#Sycophant.EmbeddingRequest<"
      assert result =~ "cohere:embed-v3"
      assert result =~ "inputs: 2"
    end
  end

  describe "EmbeddingResponse" do
    test "shows types and vector count" do
      resp = %Sycophant.EmbeddingResponse{
        embeddings: %{float: [[0.1, 0.2], [0.3, 0.4]]},
        model: "embed-v3"
      }

      result = inspect(resp)
      assert result =~ "#Sycophant.EmbeddingResponse<"
      assert result =~ "vectors: 2"
      assert result =~ ":float"
    end
  end

  describe "Response" do
    test "shows text, model, finish_reason, and usage" do
      resp = %Sycophant.Response{
        text: "Hello! How can I help you today?",
        model: "claude-haiku-4-5-20251001",
        finish_reason: :stop,
        context: %Sycophant.Context{},
        usage: %Sycophant.Usage{input_tokens: 15, output_tokens: 42, total_cost: 0.0012}
      }

      result = inspect(resp)
      assert result =~ "#Sycophant.Response<"
      assert result =~ "Hello!"
      assert result =~ ":stop"
      assert result =~ "#Sycophant.Usage<"
    end

    test "truncates long text" do
      resp = %Sycophant.Response{
        text: String.duplicate("x", 60),
        context: %Sycophant.Context{}
      }

      result = inspect(resp)
      assert result =~ "..."
    end

    test "omits raw and context" do
      resp = %Sycophant.Response{
        text: "hi",
        context: %Sycophant.Context{messages: [Sycophant.Message.user("hi")]},
        raw: %{"id" => "msg_123"}
      }

      result = inspect(resp)
      refute result =~ "raw:"
      refute result =~ "context:"
    end
  end

  describe "Agent.Callbacks" do
    test "shows set callbacks" do
      cb = %Sycophant.Agent.Callbacks{
        on_response: fn _r -> :ok end,
        on_tool_call: fn _tc -> :approve end
      }

      result = inspect(cb)
      assert result =~ "#Sycophant.Agent.Callbacks<"
      assert result =~ "on_response:"
      assert result =~ "on_tool_call:"
    end

    test "omits nil callbacks" do
      cb = %Sycophant.Agent.Callbacks{}
      result = inspect(cb)
      refute result =~ "on_response"
    end
  end

  describe "Agent.Stats" do
    test "shows turn count, tokens, and cost" do
      stats = %Sycophant.Agent.Stats{
        turns: [],
        total_input_tokens: 450,
        total_output_tokens: 120,
        total_cost: 0.0089
      }

      result = inspect(stats)
      assert result =~ "#Sycophant.Agent.Stats<"
      assert result =~ "450+120"
      assert result =~ "0.0089"
    end
  end

  describe "Agent.Stats.Turn" do
    test "shows compact turn info" do
      turn = %Sycophant.Agent.Stats.Turn{
        input_tokens: 100,
        output_tokens: 50,
        finish_reason: :stop
      }

      result = inspect(turn)
      assert result =~ "#Sycophant.Agent.Stats.Turn<"
      assert result =~ "in: 100"
      assert result =~ "out: 50"
    end
  end

  describe "Agent.State" do
    test "shows model and step/retry ratios" do
      {:ok, state} = Sycophant.Agent.State.new(model: "anthropic:claude-haiku-4-5-20251001")
      result = inspect(state)
      assert result =~ "#Sycophant.Agent.State<"
      assert result =~ "anthropic:claude-haiku-4-5-20251001"
      assert result =~ "0/10"
      assert result =~ "0/3"
    end
  end
end
