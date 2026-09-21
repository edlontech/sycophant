defmodule SycophantTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Context
  alias Sycophant.EmbeddingRequest
  alias Sycophant.Error
  alias Sycophant.EvaluationResponse
  alias Sycophant.Message
  alias Sycophant.Response

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

  defp eval_questions do
    %{
      department: %{
        type: :choice,
        instructions: "Which team should handle this ticket?",
        criteria: %{billing: "Billing and payments", support: "Technical support"}
      },
      urgent: %{type: :boolean, instructions: "Does this need immediate attention?"},
      severity: %{
        type: :score,
        instructions: "Rate severity from 1 to 5",
        criteria: ["1", "2", "3", "4", "5"]
      }
    }
  end

  defp typesafe_fixture_body do
    %{
      "model" => "jev-1.13.0",
      "answers" => %{
        "department" => %{
          "type" => "choice",
          "choice" => "billing",
          "probabilities" => %{"billing" => 0.8, "support" => 0.2}
        },
        "urgent" => %{"type" => "noul", "noul" => 0.93},
        "severity" => %{"type" => "score", "score" => 1.05},
        "unrequested" => %{"type" => "noul", "noul" => 0.5}
      },
      "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.01}
    }
  end

  describe "generate_text/3" do
    test "delegates to Pipeline and returns Response" do
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
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      assert {:ok, %Response{text: "Hello!"}} =
               Sycophant.generate_text("openai:gpt-4o", [Message.user("Hi")])
    end
  end

  describe "generate_text/3 with Context" do
    test "accepts Context with accumulated messages" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "id" => "resp-1",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Hello!"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      {:ok, resp1} = Sycophant.generate_text("openai:gpt-4o", [Message.user("Hi")])

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        input = payload["input"]
        assert length(input) == 3

        {:ok,
         %{
           "id" => "resp-2",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "World!"}]
             }
           ],
           "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
         }}
      end)

      ctx = Context.add(resp1.context, Message.user("Continue"))

      {:ok, resp2} = Sycophant.generate_text("openai:gpt-4o", ctx)

      assert resp2.text == "World!"
      assert length(Response.messages(resp2)) == 4
    end

    test "carries params from context through continuation" do
      model = build_model()
      provider = build_provider()

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        {:ok,
         %{
           "id" => "resp-1",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
         }}
      end)

      {:ok, resp} =
        Sycophant.generate_text("openai:gpt-4o", [Message.user("Hi")], temperature: 0.7)

      assert resp.context.params.temperature == 0.7

      expect(Sycophant.Transport, :call, fn payload, _opts ->
        assert payload["temperature"] == 0.7

        {:ok,
         %{
           "id" => "resp-2",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
         }}
      end)

      ctx = Context.add(resp.context, Message.user("More"))
      assert {:ok, _} = Sycophant.generate_text("openai:gpt-4o", ctx)
    end
  end

  describe "generate_object/4" do
    test "returns validated object from JSON response" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": "Alice", "age": 30})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:ok, %Response{object: %{name: "Alice", age: 30}}} =
               Sycophant.generate_object(
                 "openai:gpt-4o",
                 [Message.user("Give me a person")],
                 schema
               )
    end

    test "returns error when response fails validation" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": 123})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               Sycophant.generate_object(
                 "openai:gpt-4o",
                 [Message.user("Give me a person")],
                 schema
               )
    end

    test "skips validation with validate: false" do
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
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"name": "Alice", "age": 30})}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      assert {:ok, %Response{object: %{"name" => "Alice", "age" => 30}}} =
               Sycophant.generate_object(
                 "openai:gpt-4o",
                 [Message.user("Give me a person")],
                 schema,
                 validate: false
               )
    end
  end

  describe "generate_object/4 with Context" do
    test "passes context and schema through to pipeline" do
      model = build_model()
      provider = build_provider()
      counter = :counters.new(1, [:atomics])

      stub(LLMDB, :model, fn "openai:gpt-4o" -> {:ok, model} end)
      stub(LLMDB, :provider, fn :openai -> {:ok, provider} end)
      stub(System, :get_env, fn "OPENAI_API_KEY" -> "sk-test-key" end)

      stub(Sycophant.Transport, :call, fn _payload, _opts ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        json =
          case count do
            1 -> ~s({"name": "Alice", "age": 30})
            2 -> ~s({"name": "Bob", "age": 25})
          end

        {:ok,
         %{
           "id" => "resp-#{count}",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => json}]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end)

      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

      {:ok, resp1} =
        Sycophant.generate_object(
          "openai:gpt-4o",
          [Message.user("Give me a person")],
          schema
        )

      assert resp1.object == %{name: "Alice", age: 30}

      ctx = Context.add(resp1.context, Message.user("Give me another"))

      {:ok, resp2} = Sycophant.generate_object("openai:gpt-4o", ctx, schema)

      assert resp2.object == %{name: "Bob", age: 25}
    end
  end

  describe "evaluate/4" do
    test "returns answers under the caller's atom question keys" do
      stub(Sycophant.Transport, :call_raw, fn _payload, opts ->
        assert opts[:base_url] == "https://api.typesafe.ai"
        assert opts[:path] == "/v1/systemone"

        [{Tesla.Middleware.Headers, headers}] = opts[:auth_middlewares]
        assert {"authorization", "Bearer k"} in headers

        {:ok, {typesafe_fixture_body(), []}}
      end)

      assert {:ok, %EvaluationResponse{} = res} =
               Sycophant.evaluate(
                 "typesafe:jev-latest",
                 %{ticket: "Refund me"},
                 eval_questions(),
                 credentials: %{api_key: "k"}
               )

      assert res.answers.department.value == "billing"
      assert res.answers.urgent.probability == 0.93
      assert res.answers.urgent.value == nil
      assert res.answers.severity.value == 1.05
      assert res.answers["unrequested"].probability == 0.5
    end

    test "returns answers under the caller's string question keys" do
      stub(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {typesafe_fixture_body(), []}}
      end)

      string_questions = Map.new(eval_questions(), fn {k, v} -> {to_string(k), v} end)

      assert {:ok, res} =
               Sycophant.evaluate(
                 "typesafe:jev-latest",
                 %{ticket: "Refund me"},
                 string_questions,
                 credentials: %{api_key: "k"}
               )

      assert res.answers["department"].value == "billing"
      assert res.answers["urgent"].probability == 0.93
    end

    test "credentials base_url overrides the LLMDB base URL" do
      stub(Sycophant.Transport, :call_raw, fn _payload, opts ->
        assert opts[:base_url] == "https://custom.typesafe.endpoint"
        {:ok, {typesafe_fixture_body(), []}}
      end)

      assert {:ok, _} =
               Sycophant.evaluate(
                 "typesafe:jev-latest",
                 "state",
                 eval_questions(),
                 credentials: %{api_key: "k", base_url: "https://custom.typesafe.endpoint"}
               )
    end

    test "returns MissingCredentials without calling Transport when no credentials resolve" do
      stub(System, :get_env, fn "TYPESAFE_API_KEY" -> nil end)
      reject(&Sycophant.Transport.call_raw/2)

      assert {:error, %Error.Invalid.MissingCredentials{}} =
               Sycophant.evaluate("typesafe:jev-latest", "state", eval_questions())
    end

    test "a Transport error is returned unchanged" do
      stub(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 529, body: "overloaded")}
      end)

      assert {:error, %Error.Provider.ServerError{status: 529}} =
               Sycophant.evaluate(
                 "typesafe:jev-latest",
                 "state",
                 eval_questions(),
                 credentials: %{api_key: "k"}
               )
    end

    test "rejects a chat call on the evaluation-only model without calling Transport" do
      reject(&Sycophant.Transport.call/2)

      assert {:error, _} = Sycophant.generate_text("typesafe:jev-latest", [Message.user("hi")])
    end

    test "rejects embed/2 on the evaluation-only model without calling Transport" do
      reject(&Sycophant.Transport.call_raw/2)

      request = %EmbeddingRequest{inputs: ["hello"], model: "typesafe:jev-latest"}
      assert {:error, _} = Sycophant.embed(request)
    end

    test "rejects evaluate/4 on a chat-only model without calling Transport" do
      reject(&Sycophant.Transport.call_raw/2)

      assert {:error, _} =
               Sycophant.evaluate(
                 "openai:gpt-4o-mini",
                 "state",
                 eval_questions(),
                 credentials: %{api_key: "k"}
               )
    end

    test "rejects evaluate/4 on a provider not in the LLMDB allow list without calling Transport" do
      reject(&Sycophant.Transport.call_raw/2)

      assert {:error, _} =
               Sycophant.evaluate(
                 "cloudflare_workers_ai:typesafe/jev",
                 "state",
                 eval_questions(),
                 credentials: %{api_key: "k"}
               )

      assert {:error, _} =
               Sycophant.evaluate(
                 "vercel:typesafe-ai/jev",
                 "state",
                 eval_questions(),
                 credentials: %{api_key: "k"}
               )
    end

    test "rejects evaluate/4 with invalid questions without calling Transport" do
      reject(&Sycophant.Transport.call_raw/2)

      assert {:error, _} =
               Sycophant.evaluate(
                 "typesafe:jev-latest",
                 "state",
                 %{department: %{type: :not_a_real_type}}
               )
    end
  end
end
