defmodule Sycophant.PipelineAuthConstraintsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Sycophant.Auth
  alias Sycophant.Auth.RequestConstraints
  alias Sycophant.Message
  alias Sycophant.Pipeline
  alias Sycophant.Transport

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    model = %LLMDB.Model{
      id: "gpt-4o",
      provider: :openai,
      extra: %{wire: %{protocol: "openai_responses"}}
    }

    provider = %LLMDB.Provider{id: :openai, base_url: "https://api.openai.com/v1"}
    stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
    stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)

    :ok
  end

  test "credential constraints drop params, override params and force hidden streaming" do
    expect(Auth, :request_constraints_for, fn :openai, %{api_key: "sk-test"}, model_info ->
      assert model_info.model_id == "gpt-4o"

      %RequestConstraints{
        unsupported_params: [:temperature],
        forced_params: %{store: false},
        require_stream: true
      }
    end)

    stub(Transport, :call, fn _, _ -> flunk("expected streaming transport") end)

    expect(Transport, :stream, fn payload, _opts, on_event ->
      assert payload["store"] == false
      assert payload["stream"] == true
      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "forced_stream")

      {:ok, on_event.(stream_events())}
    end)

    assert {:ok, response} =
             Pipeline.call([Message.user("Hi")],
               model: "openai:gpt-4o",
               credentials: %{api_key: "sk-test"},
               temperature: 0.5,
               store: true
             )

    assert response.text == "Hello!"
    assert response.context.stream == nil
    assert response.context.params.store == false
    refute Map.has_key?(response.context.params, :temperature)
  end

  test "required streaming preserves the caller callback and delivers chunks" do
    stub(Auth, :request_constraints_for, fn :openai, _, _ ->
      %RequestConstraints{
        unsupported_params: [:temperature],
        forced_params: %{store: false},
        require_stream: true
      }
    end)

    expect(Transport, :stream, fn payload, _opts, on_event ->
      assert payload["store"] == false
      refute Map.has_key?(payload, "temperature")
      {:ok, on_event.(stream_events())}
    end)

    test_pid = self()
    callback = fn chunk -> send(test_pid, {:chunk, chunk}) end

    assert {:ok, response} =
             Pipeline.call([Message.user("Hi")],
               model: "openai:gpt-4o",
               credentials: %{api_key: "sk-test"},
               temperature: 0.5,
               stream: callback
             )

    assert_received {:chunk, %Sycophant.StreamChunk{type: :text_delta, data: "Hello!"}}
    assert response.context.stream == callback
  end

  test "explicit false streaming is forced without retaining the internal callback" do
    stub(Auth, :request_constraints_for, fn :openai, _, _ ->
      %RequestConstraints{require_stream: true}
    end)

    expect(Transport, :stream, fn payload, _opts, on_event ->
      assert payload["stream"] == true
      {:ok, on_event.(stream_events())}
    end)

    assert {:ok, response} =
             Pipeline.call([Message.user("Hi")],
               model: "openai:gpt-4o",
               credentials: %{api_key: "sk-test"},
               stream: false
             )

    assert response.context.stream == nil
  end

  test "empty constraints preserve the API-key payload and synchronous transport" do
    expect(Transport, :call, fn payload, opts ->
      assert payload == %{
               "model" => "gpt-4o",
               "input" => [%{"role" => "user", "content" => "Hi"}],
               "temperature" => 0.5,
               "store" => true
             }

      assert opts[:base_url] == "https://api.openai.com/v1"
      assert opts[:path] == "/responses"
      {:ok, %{"id" => "resp-123", "output" => [], "usage" => %{}}}
    end)

    assert {:ok, response} =
             Pipeline.call([Message.user("Hi")],
               model: "openai:gpt-4o",
               credentials: %{api_key: "sk-test"},
               temperature: 0.5,
               store: true
             )

    assert response.context.stream == nil
    assert response.context.params.temperature == 0.5
    assert response.context.params.store == true
  end

  test "access-token constraints survive an automatically executed tool loop" do
    stub(Transport, :call, fn _, _ -> flunk("expected streaming transport on both requests") end)

    expect(Transport, :stream, fn payload, _opts, on_event ->
      assert payload["store"] == false
      assert payload["stream"] == true
      refute Map.has_key?(payload, "temperature")

      events = [
        %{
          event: "response.completed",
          data:
            JSON.encode!(%{
              "response" => %{
                "id" => "resp-tool",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "function_call",
                    "call_id" => "call_1",
                    "name" => "weather",
                    "arguments" => "{}"
                  }
                ],
                "usage" => %{}
              }
            })
        }
      ]

      {:ok, on_event.(events)}
    end)

    expect(Transport, :stream, fn payload, _opts, on_event ->
      assert payload["store"] == false
      assert payload["stream"] == true
      refute Map.has_key?(payload, "temperature")
      assert Enum.any?(payload["input"], &(&1["type"] == "function_call_output"))
      {:ok, on_event.(stream_events())}
    end)

    test_pid = self()

    tool = %Sycophant.Tool{
      name: "weather",
      description: "Get weather",
      parameters: Zoi.map(%{}),
      function: fn _args ->
        send(test_pid, :tool_executed)
        "Sunny"
      end
    }

    assert {:ok, response} =
             Pipeline.call([Message.user("Weather?")],
               model: "openai:gpt-4o",
               credentials: %{access_token: "access"},
               tools: [tool],
               temperature: 0.5,
               store: true
             )

    assert_received :tool_executed
    assert response.text == "Hello!"
    assert response.context.stream == nil
  end

  defp stream_events do
    [
      %{event: "response.output_text.delta", data: JSON.encode!(%{"delta" => "Hello!"})},
      %{
        event: "response.completed",
        data:
          JSON.encode!(%{
            "response" => %{
              "id" => "resp-123",
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [%{"type" => "output_text", "text" => "Hello!"}]
                }
              ],
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            }
          })
      }
    ]
  end
end
