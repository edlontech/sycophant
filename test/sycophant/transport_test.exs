defmodule Sycophant.TransportTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.AuthenticationFailed
  alias Sycophant.Error.Provider.BadRequest
  alias Sycophant.Error.Provider.ModelNotFound
  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Error.Unknown.Unknown
  alias Sycophant.Transport

  @base_opts [
    base_url: "https://api.example.com",
    path: "/v1/chat/completions"
  ]

  defp fake_adapter(status, body, headers \\ []) do
    fn env ->
      {:ok, %{env | status: status, body: body, headers: headers}}
    end
  end

  defp call_with(adapter_fn, extra_opts \\ []) do
    opts =
      @base_opts
      |> Keyword.merge(extra_opts)
      |> Keyword.put(:adapter, adapter_fn)

    Transport.call(%{"model" => "gpt-4o"}, opts)
  end

  describe "call/2 success" do
    test "returns decoded body on 200" do
      adapter = fake_adapter(200, %{"id" => "chatcmpl-123", "choices" => []})
      assert {:ok, %{"id" => "chatcmpl-123", "choices" => []}} = call_with(adapter)
    end

    test "returns decoded body on 201" do
      adapter = fake_adapter(201, %{"id" => "resp-1"})
      assert {:ok, %{"id" => "resp-1"}} = call_with(adapter)
    end
  end

  describe "call/2 authentication errors" do
    test "maps 401 to AuthenticationFailed" do
      adapter = fake_adapter(401, %{"error" => "invalid_api_key"})
      assert {:error, %AuthenticationFailed{status: 401}} = call_with(adapter)
    end
  end

  describe "call/2 rate limiting" do
    test "maps 429 to RateLimited with retry_after from header" do
      adapter = fake_adapter(429, %{}, [{"retry-after", "30.5"}])
      assert {:error, %RateLimited{retry_after: 30.5}} = call_with(adapter)
    end

    test "maps 429 to RateLimited with nil when no retry-after header" do
      adapter = fake_adapter(429, %{}, [])
      assert {:error, %RateLimited{retry_after: nil}} = call_with(adapter)
    end
  end

  describe "call/2 not found" do
    test "maps 404 to ModelNotFound" do
      adapter = fake_adapter(404, %{"error" => "model not found"})
      assert {:error, %ModelNotFound{}} = call_with(adapter)
    end
  end

  describe "call/2 server errors" do
    test "maps 500 to ServerError" do
      adapter = fake_adapter(500, %{"error" => "internal"})
      assert {:error, %ServerError{status: 500}} = call_with(adapter)
    end

    test "maps 503 to ServerError" do
      adapter = fake_adapter(503, %{"error" => "unavailable"})
      assert {:error, %ServerError{status: 503}} = call_with(adapter)
    end

    test "maps 400 to BadRequest" do
      adapter = fake_adapter(400, %{"error" => "bad request"})
      assert {:error, %BadRequest{status: 400}} = call_with(adapter)
    end
  end

  describe "call/2 connection errors" do
    test "wraps connection errors as Unknown" do
      adapter = fn _env -> {:error, :timeout} end
      assert {:error, %Unknown{}} = call_with(adapter)
    end
  end

  describe "call/2 auth middlewares" do
    test "includes caller-provided auth middlewares in the client" do
      adapter = fn env ->
        auth = Tesla.get_header(env, "authorization")
        {:ok, %{env | status: 200, body: %{"auth_header" => auth}}}
      end

      auth = [{Tesla.Middleware.Headers, [{"authorization", "Bearer sk-test"}]}]

      assert {:ok, %{"auth_header" => "Bearer sk-test"}} =
               call_with(adapter, auth_middlewares: auth)
    end

    test "works without auth middlewares" do
      adapter = fn env ->
        auth = Tesla.get_header(env, "authorization")
        {:ok, %{env | status: 200, body: %{"auth_header" => auth}}}
      end

      assert {:ok, %{"auth_header" => nil}} = call_with(adapter)
    end
  end

  describe "call/2 caller middlewares" do
    test "includes extra middlewares passed via opts" do
      adapter = fake_adapter(200, %{"ok" => true})

      assert {:ok, %{"ok" => true}} =
               call_with(adapter, middlewares: [{Tesla.Middleware.Logger, []}])
    end
  end

  describe "stream/3" do
    test "passes SSE event stream to on_event callback" do
      raw_chunks = ["data: {\"text\":\"hello\"}\n\n"]
      stream = Stream.map(raw_chunks, & &1)

      adapter = fn env ->
        {:ok,
         %{env | status: 200, body: stream, headers: [{"content-type", "text/event-stream"}]}}
      end

      on_event = fn event_stream ->
        Enum.to_list(event_stream)
      end

      opts = @base_opts |> Keyword.put(:adapter, adapter)

      assert {:ok, [%{data: "{\"text\":\"hello\"}"}]} =
               Transport.stream(%{"model" => "gpt-4o"}, opts, on_event)
    end

    test "maps 401 to AuthenticationFailed" do
      adapter = fn env ->
        {:ok, %{env | status: 401, body: "unauthorized"}}
      end

      on_event = fn _ -> flunk("should not be called") end
      opts = @base_opts |> Keyword.put(:adapter, adapter)
      assert {:error, %AuthenticationFailed{}} = Transport.stream(%{}, opts, on_event)
    end

    test "maps 429 to RateLimited" do
      adapter = fn env ->
        {:ok, %{env | status: 429, body: "", headers: [{"retry-after", "10"}]}}
      end

      on_event = fn _ -> flunk("should not be called") end
      opts = @base_opts |> Keyword.put(:adapter, adapter)
      assert {:error, %RateLimited{retry_after: 10.0}} = Transport.stream(%{}, opts, on_event)
    end

    test "maps 500 to ServerError" do
      adapter = fn env ->
        {:ok, %{env | status: 500, body: "internal error"}}
      end

      on_event = fn _ -> flunk("should not be called") end
      opts = @base_opts |> Keyword.put(:adapter, adapter)
      assert {:error, %ServerError{status: 500}} = Transport.stream(%{}, opts, on_event)
    end

    test "wraps connection errors as Unknown" do
      adapter = fn _env -> {:error, :timeout} end
      on_event = fn _ -> flunk("should not be called") end
      opts = @base_opts |> Keyword.put(:adapter, adapter)
      assert {:error, %Unknown{}} = Transport.stream(%{}, opts, on_event)
    end
  end
end
