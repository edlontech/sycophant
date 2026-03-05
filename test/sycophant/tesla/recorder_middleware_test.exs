defmodule Sycophant.Tesla.RecorderMiddlewareTest do
  use ExUnit.Case, async: true

  alias Sycophant.Tesla.RecorderMiddleware

  describe "process dictionary helpers" do
    test "get_recording returns nil when nothing is set" do
      assert RecorderMiddleware.get_recording() == nil
    end

    test "set/get/clear recording lifecycle" do
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      RecorderMiddleware.set_recording("openai/gpt-4o/test")
      assert RecorderMiddleware.get_recording() == "openai/gpt-4o/test"

      RecorderMiddleware.clear_recording()
      assert RecorderMiddleware.get_recording() == nil
    end
  end

  describe "call/3 with no recording set" do
    test "passes through to next middleware" do
      env = %Tesla.Env{method: :get, url: "https://example.com/test"}

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: "passthrough"}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200, body: "passthrough"}} =
               RecorderMiddleware.call(env, next, [])
    end
  end

  describe "replay mode" do
    @tag :tmp_dir
    test "replays from fixture file", %{tmp_dir: tmp_dir} do
      name = "test/replay_basic"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      fixture = %{
        "metadata" => %{
          "recorded_at" => "2026-03-04T12:00:00Z",
          "sycophant_version" => "0.1.0",
          "model" => "gpt-4o",
          "provider" => "api.openai.com"
        },
        "request" => %{
          "method" => "post",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => [["authorization", "[REDACTED]"]],
          "body" => %{"model" => "gpt-4o"}
        },
        "response" => %{
          "status" => 200,
          "headers" => [["content-type", "application/json"]],
          "body" => %{
            "id" => "chatcmpl-123",
            "choices" => [%{"message" => %{"content" => "Hello"}}]
          }
        }
      }

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, JSON.encode!(fixture))

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://api.openai.com/v1/chat/completions"}

      assert {:ok, %Tesla.Env{status: 200, body: body}} =
               RecorderMiddleware.call(env, [], fixtures_path: tmp_dir)

      assert {:ok, %{"id" => "chatcmpl-123"}} = JSON.decode(body)
    end

    @tag :tmp_dir
    test "decodes both tuple and list header formats", %{tmp_dir: tmp_dir} do
      name = "test/replay_headers"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      fixture = %{
        "metadata" => %{},
        "request" => %{
          "method" => "post",
          "url" => "https://example.com",
          "headers" => [],
          "body" => %{}
        },
        "response" => %{
          "status" => 200,
          "headers" => [
            ["content-type", "application/json"],
            ["x-request-id", "abc-123"]
          ],
          "body" => %{"ok" => true}
        }
      }

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, JSON.encode!(fixture))

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://example.com"}

      assert {:ok, %Tesla.Env{headers: headers}} =
               RecorderMiddleware.call(env, [], fixtures_path: tmp_dir)

      assert {"content-type", "application/json"} in headers
      assert {"x-request-id", "abc-123"} in headers
    end
  end

  describe "replay with corrupt fixture" do
    @tag :tmp_dir
    test "returns error instead of raising", %{tmp_dir: tmp_dir} do
      name = "test/corrupt_fixture"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, "not valid json {{{")

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://example.com"}

      assert {:error, message} =
               RecorderMiddleware.call(env, [], fixtures_path: tmp_dir)

      assert message =~ "Fixture not found"
    end
  end

  describe "replay with missing fixture" do
    @tag :tmp_dir
    test "returns error with helpful message", %{tmp_dir: tmp_dir} do
      RecorderMiddleware.set_recording("nonexistent/fixture")
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "/test"}

      assert {:error, message} =
               RecorderMiddleware.call(env, [], fixtures_path: tmp_dir)

      assert message =~ "Fixture not found"
      assert message =~ "RECORD=true"
    end
  end

  describe "record mode" do
    @tag :tmp_dir
    test "records request/response to fixture file", %{tmp_dir: tmp_dir} do
      name = "test/record_basic"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [
          {"authorization", "Bearer sk-secret"},
          {"content-type", "application/json"}
        ],
        body: JSON.encode!(%{"model" => "gpt-4o", "messages" => []})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: JSON.encode!(%{"id" => "cmpl-1"})}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200}} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: true)

      assert File.exists?(fixture_path)

      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)

      assert fixture["response"]["status"] == 200
      assert fixture["response"]["body"]["id"] == "cmpl-1"
      assert fixture["request"]["method"] == "post"
      assert fixture["metadata"]["model"] == "gpt-4o"
      assert fixture["metadata"]["provider"] == "api.openai.com"
    end

    @tag :tmp_dir
    test "redacts sensitive headers", %{tmp_dir: tmp_dir} do
      name = "test/record_redact"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [
          {"authorization", "Bearer sk-secret-key"},
          {"x-api-key", "my-api-key"},
          {"api-key", "azure-key"},
          {"content-type", "application/json"}
        ],
        body: JSON.encode!(%{"model" => "gpt-4o"})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: "{}"}}
         end}
      ]

      assert {:ok, _} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: true)

      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)

      request_headers = Map.new(fixture["request"]["headers"], fn [k, v] -> {k, v} end)
      assert request_headers["authorization"] == "[REDACTED]"
      assert request_headers["x-api-key"] == "[REDACTED]"
      assert request_headers["api-key"] == "[REDACTED]"
      assert request_headers["content-type"] == "application/json"
    end

    @tag :tmp_dir
    test "redacts headers case-insensitively", %{tmp_dir: tmp_dir} do
      name = "test/record_case_insensitive"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [
          {"Authorization", "Bearer sk-secret"},
          {"X-Api-Key", "my-key"},
          {"Api-Key", "azure-key"},
          {"Content-Type", "application/json"}
        ],
        body: JSON.encode!(%{"model" => "gpt-4o"})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: "{}"}}
         end}
      ]

      assert {:ok, _} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: true)

      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)

      request_headers = Map.new(fixture["request"]["headers"], fn [k, v] -> {k, v} end)
      assert request_headers["Authorization"] == "[REDACTED]"
      assert request_headers["X-Api-Key"] == "[REDACTED]"
      assert request_headers["Api-Key"] == "[REDACTED]"
      assert request_headers["Content-Type"] == "application/json"
    end

    @tag :tmp_dir
    test "propagates errors from next middleware", %{tmp_dir: tmp_dir} do
      RecorderMiddleware.set_recording("test/record_error")
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://example.com"}

      next = [
        {:fn, fn _env -> {:error, :timeout} end}
      ]

      assert {:error, :timeout} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: true)
    end

    @tag :tmp_dir
    test "collects streaming body and marks fixture as streaming", %{tmp_dir: tmp_dir} do
      name = "test/record_stream"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      sse_chunks = ["data: {\"id\":\"1\"}\n\n", "data: {\"id\":\"2\"}\n\n", "data: [DONE]\n\n"]

      env = %Tesla.Env{
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [{"content-type", "application/json"}],
        body: JSON.encode!(%{"model" => "gpt-4o", "stream" => true})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: Stream.map(sse_chunks, & &1)}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200, body: body}} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: true)

      assert is_binary(body)
      assert body =~ "data: {\"id\":\"1\"}"

      assert File.exists?(fixture_path)
      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)

      assert fixture["metadata"]["streaming"] == true
      assert is_binary(fixture["response"]["body"])
      assert fixture["response"]["body"] =~ "data: [DONE]"
    end
  end

  describe "record mode skips existing fixtures" do
    @tag :tmp_dir
    test "replays when fixture already exists and record mode is :record", %{tmp_dir: tmp_dir} do
      name = "test/already_recorded"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      fixture = %{
        "metadata" => %{
          "recorded_at" => "2026-03-04T12:00:00Z",
          "sycophant_version" => "0.1.0",
          "model" => "gpt-4o",
          "provider" => "api.openai.com"
        },
        "request" => %{
          "method" => "post",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => [],
          "body" => %{"model" => "gpt-4o"}
        },
        "response" => %{
          "status" => 200,
          "headers" => [["content-type", "application/json"]],
          "body" => %{"id" => "existing-fixture"}
        }
      }

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, JSON.encode!(fixture))

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://api.openai.com/v1/chat/completions"}

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: JSON.encode!(%{"id" => "fresh-from-api"})}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200, body: body}} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: :record)

      assert {:ok, %{"id" => "existing-fixture"}} = JSON.decode(body)
    end

    @tag :tmp_dir
    test "records when fixture does not exist and record mode is :record", %{tmp_dir: tmp_dir} do
      name = "test/new_recording"

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [{"content-type", "application/json"}],
        body: JSON.encode!(%{"model" => "gpt-4o", "messages" => []})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: JSON.encode!(%{"id" => "newly-recorded"})}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200}} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: :record)

      fixture_path = Path.join([tmp_dir, "#{name}.json"])
      assert File.exists?(fixture_path)

      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)
      assert fixture["response"]["body"]["id"] == "newly-recorded"
    end

    @tag :tmp_dir
    test "force mode re-records even when fixture exists", %{tmp_dir: tmp_dir} do
      name = "test/force_rerecord"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      fixture = %{
        "metadata" => %{},
        "request" => %{
          "method" => "post",
          "url" => "https://example.com",
          "headers" => [],
          "body" => %{}
        },
        "response" => %{
          "status" => 200,
          "headers" => [["content-type", "application/json"]],
          "body" => %{"id" => "old-fixture"}
        }
      }

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, JSON.encode!(fixture))

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{
        method: :post,
        url: "https://example.com",
        headers: [{"content-type", "application/json"}],
        body: JSON.encode!(%{"model" => "gpt-4o"})
      }

      next = [
        {:fn,
         fn %Tesla.Env{} = env ->
           {:ok, %{env | status: 200, body: JSON.encode!(%{"id" => "re-recorded"})}}
         end}
      ]

      assert {:ok, %Tesla.Env{status: 200}} =
               RecorderMiddleware.call(env, next, fixtures_path: tmp_dir, record: :force)

      {:ok, content} = File.read(fixture_path)
      fixture = JSON.decode!(content)
      assert fixture["response"]["body"]["id"] == "re-recorded"
    end
  end

  describe "replay streaming fixture" do
    @tag :tmp_dir
    test "returns raw body without JSON encoding", %{tmp_dir: tmp_dir} do
      name = "test/replay_stream"
      fixture_path = Path.join([tmp_dir, "#{name}.json"])

      sse_body = "data: {\"id\":\"1\"}\n\ndata: [DONE]\n\n"

      fixture = %{
        "metadata" => %{
          "recorded_at" => "2026-03-05T12:00:00Z",
          "sycophant_version" => "0.1.0",
          "model" => "gpt-4o",
          "provider" => "api.openai.com",
          "streaming" => true
        },
        "request" => %{
          "method" => "post",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => [],
          "body" => %{"model" => "gpt-4o", "stream" => true}
        },
        "response" => %{
          "status" => 200,
          "headers" => [["content-type", "text/event-stream"]],
          "body" => sse_body
        }
      }

      File.mkdir_p!(Path.dirname(fixture_path))
      File.write!(fixture_path, JSON.encode!(fixture))

      RecorderMiddleware.set_recording(name)
      on_exit(fn -> RecorderMiddleware.clear_recording() end)

      env = %Tesla.Env{method: :post, url: "https://api.openai.com/v1/chat/completions"}

      assert {:ok, %Tesla.Env{status: 200, body: body}} =
               RecorderMiddleware.call(env, [], fixtures_path: tmp_dir)

      assert body == sse_body
    end
  end
end
