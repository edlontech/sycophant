defmodule Sycophant.PipelineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Error
  alias Sycophant.Message
  alias Sycophant.Pipeline
  alias Sycophant.Response
  alias Sycophant.Telemetry

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_model(attrs \\ %{}) do
    defaults = %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: :openai,
      provider_model_id: nil,
      base_url: nil,
      extra: %{wire: %{protocol: "openai_responses"}}
    }

    struct(LLMDB.Model, Map.merge(defaults, attrs))
  end

  defp build_provider(attrs \\ %{}) do
    defaults = %{
      id: :openai,
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      env: ["OPENAI_API_KEY"]
    }

    struct(LLMDB.Provider, Map.merge(defaults, attrs))
  end

  defp stub_happy_path do
    model = build_model()
    provider = build_provider()

    stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
    stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
    stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

    stub(Sycophant.Transport, :call, fn _payload, _opts ->
      {:ok,
       %{
         "id" => "resp-123",
         "output" => [
           %{
             "type" => "message",
             "content" => [%{"type" => "output_text", "text" => "Hello!"}]
           }
         ],
         "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
       }}
    end)
  end

  defp default_messages do
    [Message.user("Hi")]
  end

  defp default_opts do
    [model: "openai:gpt-4o"]
  end

  describe "call/2 happy path" do
    test "resolves model, encodes, transports, decodes and returns Response" do
      stub_happy_path()

      assert {:ok, %Response{text: "Hello!"}} =
               Pipeline.call(default_messages(), default_opts())
    end

    test "response includes usage information" do
      stub_happy_path()

      assert {:ok, %Response{usage: usage}} =
               Pipeline.call(default_messages(), default_opts())

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "passes encoded request payload to transport" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn payload, opts ->
        assert is_map(payload)
        assert payload["model"] == "gpt-4o"
        assert payload["input"] != nil
        assert opts[:base_url] == "https://api.openai.com/v1"
        assert opts[:path] == "/responses"

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Hello!"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())
    end

    test "builds auth middlewares from resolved credentials" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        auth_middlewares = opts[:auth_middlewares]
        assert length(auth_middlewares) == 1

        [{Tesla.Middleware.Headers, headers}] = auth_middlewares
        assert {"authorization", "Bearer sk-test-key"} in headers

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      end)

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())
    end
  end

  describe "call/2 error cases" do
    test "returns MissingModel error when model is nil" do
      assert {:error, %Error.Invalid.MissingModel{}} =
               Pipeline.call(default_messages(), [])
    end

    test "returns InvalidParams error for invalid parameters" do
      stub_happy_path()

      opts = default_opts() ++ [temperature: 5.0]

      assert {:error, %Error.Invalid.InvalidParams{}} =
               Pipeline.call(default_messages(), opts)
    end

    test "propagates transport errors" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:error, Error.Provider.RateLimited.exception(retry_after: 30)}
      end)

      assert {:error, %Error.Provider.RateLimited{retry_after: 30}} =
               Pipeline.call(default_messages(), default_opts())
    end

    test "returns MissingCredentials when no credentials found" do
      model = build_model(%{provider: :unknown_provider})
      provider = build_provider(%{id: :unknown_provider, env: []})

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :unknown_provider -> {:ok, provider} end)

      assert {:error, %Error.Invalid.MissingCredentials{}} =
               Pipeline.call(default_messages(), default_opts())
    end
  end

  describe "call/2 telemetry" do
    setup do
      test_pid = self()
      handler_id = "pipeline-telemetry-test-#{inspect(test_pid)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits start and stop events on success" do
      stub_happy_path()

      assert {:ok, _} = Pipeline.call(default_messages(), default_opts())

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, start_meta}
      assert start_meta.model == "openai:gpt-4o"
      assert start_meta.provider == :openai

      assert_received {:telemetry_event, [:sycophant, :request, :stop], _, _}
    end

    test "emits start and error events on transport failure" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 500, body: "boom")}
      end)

      assert {:error, _} = Pipeline.call(default_messages(), default_opts())

      assert_received {:telemetry_event, [:sycophant, :request, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :request, :error], _, error_meta}
      assert error_meta.error_class == :provider
    end

    test "does not emit telemetry when model resolution fails" do
      assert {:error, %Error.Invalid.MissingModel{}} =
               Pipeline.call(default_messages(), [])

      refute_received {:telemetry_event, [:sycophant, :request, :start], _, _}
    end
  end

  describe "call/2 with per-request credentials" do
    test "uses per-request credentials over env vars" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)

      expect(Sycophant.Transport, :call, fn _payload, opts ->
        [{Tesla.Middleware.Headers, headers}] = opts[:auth_middlewares]
        assert {"authorization", "Bearer sk-custom"} in headers

        {:ok,
         %{
           "id" => "resp-123",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      end)

      opts = default_opts() ++ [credentials: %{api_key: "sk-custom"}]
      assert {:ok, _} = Pipeline.call(default_messages(), opts)
    end
  end
end
