defmodule Sycophant.EvaluationPipelineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sycophant.Error
  alias Sycophant.EvaluationPipeline
  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationResponse

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp build_eval_model(attrs \\ %{}) do
    defaults = %{
      id: "jev-latest",
      provider: :typesafe,
      provider_model_id: nil,
      extra: nil,
      base_url: nil,
      capabilities: %{chat: false, evaluate: true, embeddings: false},
      execution: %{evaluate: %{wire_protocol: "typesafe_systemone"}}
    }

    struct(LLMDB.Model, Map.merge(defaults, attrs))
  end

  defp build_provider(attrs \\ %{}) do
    defaults = %{
      id: :typesafe,
      name: "TypeSafe",
      base_url: "https://api.typesafe.ai",
      env: ["TYPESAFE_API_KEY"]
    }

    struct(LLMDB.Provider, Map.merge(defaults, attrs))
  end

  defp questions do
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

  defp fixture_body do
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
        "extra_id" => %{"type" => "noul", "noul" => 0.5}
      },
      "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.01}
    }
  end

  describe "call/2" do
    test "returns error for nil model" do
      {:ok, request} = EvaluationRequest.new(nil, "state", questions())
      assert {:error, %Error.Invalid.MissingModel{}} = EvaluationPipeline.call(request)
    end

    test "returns error for a model that does not support evaluation" do
      model = build_eval_model(%{capabilities: %{chat: true, evaluate: false, embeddings: false}})

      expect(LLMDB, :model, fn "openai:gpt-4o-mini" -> {:ok, model} end)

      {:ok, request} = EvaluationRequest.new("openai:gpt-4o-mini", "state", questions())
      assert {:error, error} = EvaluationPipeline.call(request)
      assert Exception.message(error) =~ "evaluation"
    end

    test "returns error for unknown model spec" do
      expect(LLMDB, :model, fn "fake:model" -> {:error, :not_found} end)

      {:ok, request} = EvaluationRequest.new("fake:model", "state", questions())
      assert {:error, %Error.Invalid.MissingModel{}} = EvaluationPipeline.call(request)
    end

    test "full pipeline re-keys answers to the caller's atom question keys" do
      model = build_eval_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn payload, opts ->
        assert opts[:base_url] == "https://api.typesafe.ai"
        assert opts[:path] == "/v1/systemone"

        [{Tesla.Middleware.Headers, headers}] = opts[:auth_middlewares]
        assert {"authorization", "Bearer k"} in headers

        assert payload["model"] == "jev-latest"

        {:ok, {fixture_body(), []}}
      end)

      {:ok, request} =
        EvaluationRequest.new("typesafe:jev-latest", %{ticket: "Refund me"}, questions())

      assert {:ok, %EvaluationResponse{} = response} =
               EvaluationPipeline.call(request, credentials: %{api_key: "k"})

      assert response.answers.department.value == "billing"
      assert response.answers.urgent.probability == 0.93
      assert response.answers.urgent.value == nil
      assert response.answers.severity.value == 1.05
      assert response.answers["extra_id"].probability == 0.5
      refute Map.has_key?(response.answers, :severity_missing)
      assert response.model == "jev-1.13.0"
      assert response.usage.input_tokens == 100
    end

    test "full pipeline re-keys answers to the caller's string question keys" do
      model = build_eval_model()
      provider = build_provider()

      string_questions = Map.new(questions(), fn {k, v} -> {to_string(k), v} end)

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {fixture_body(), []}}
      end)

      {:ok, request} =
        EvaluationRequest.new("typesafe:jev-latest", %{ticket: "Refund me"}, string_questions)

      assert {:ok, response} =
               EvaluationPipeline.call(request, credentials: %{api_key: "k"})

      assert response.answers["department"].value == "billing"
      assert response.answers["urgent"].probability == 0.93
    end

    test "a question the caller asked but the body omits is absent from the response" do
      model = build_eval_model()
      provider = build_provider()

      asked = Map.put(questions(), :missing, %{type: :boolean, instructions: "unanswered"})

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {fixture_body(), []}}
      end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", %{ticket: "Refund me"}, asked)

      assert {:ok, response} = EvaluationPipeline.call(request, credentials: %{api_key: "k"})

      refute Map.has_key?(response.answers, :missing)
      refute Map.has_key?(response.answers, "missing")
    end

    test "propagates transport errors unchanged" do
      model = build_eval_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 529, body: "overloaded")}
      end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", "state", questions())

      assert {:error, %Error.Provider.ServerError{status: 529}} =
               EvaluationPipeline.call(request, credentials: %{api_key: "k"})
    end

    test "returns MissingCredentials when no credentials resolve" do
      model = build_eval_model()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(Sycophant.Config, :provider, fn :typesafe -> {:error, :not_found} end)
      expect(LLMDB, :provider, 2, fn :typesafe -> {:ok, build_provider()} end)
      expect(System, :get_env, fn "TYPESAFE_API_KEY" -> nil end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", "state", questions())

      assert {:error, %Error.Invalid.MissingCredentials{}} = EvaluationPipeline.call(request)
    end
  end

  describe "call/2 with credentials base_url override" do
    test "uses base_url from credentials instead of LLMDB base_url" do
      model = build_eval_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, opts ->
        assert opts[:base_url] == "https://custom.typesafe.endpoint"
        {:ok, {fixture_body(), []}}
      end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", "state", questions())

      assert {:ok, _} =
               EvaluationPipeline.call(request,
                 credentials: %{api_key: "k", base_url: "https://custom.typesafe.endpoint"}
               )
    end
  end

  describe "call/2 telemetry" do
    setup do
      test_pid = self()
      handler_id = "evaluation-pipeline-telemetry-#{inspect(test_pid)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:sycophant, :evaluation, :start],
          [:sycophant, :evaluation, :stop],
          [:sycophant, :evaluation, :error]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits start and stop events on success" do
      model = build_eval_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:ok, {fixture_body(), []}}
      end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", "state", questions())

      assert {:ok, _} = EvaluationPipeline.call(request, credentials: %{api_key: "k"})

      assert_received {:telemetry_event, [:sycophant, :evaluation, :start], _, start_meta}
      assert start_meta.provider == :typesafe
      assert start_meta.question_count == 3

      assert_received {:telemetry_event, [:sycophant, :evaluation, :stop], _, stop_meta}
      assert stop_meta.usage == %{input_tokens: 100, output_tokens: 20}
    end

    test "emits start and error events on transport failure" do
      model = build_eval_model()
      provider = build_provider()

      expect(LLMDB, :model, fn "typesafe:jev-latest" -> {:ok, model} end)
      expect(LLMDB, :provider, fn :typesafe -> {:ok, provider} end)

      expect(Sycophant.Transport, :call_raw, fn _payload, _opts ->
        {:error, Error.Provider.ServerError.exception(status: 529, body: "overloaded")}
      end)

      {:ok, request} = EvaluationRequest.new("typesafe:jev-latest", "state", questions())

      assert {:error, _} = EvaluationPipeline.call(request, credentials: %{api_key: "k"})

      assert_received {:telemetry_event, [:sycophant, :evaluation, :start], _, _}
      assert_received {:telemetry_event, [:sycophant, :evaluation, :error], _, error_meta}
      assert error_meta.error_class == :provider
    end

    test "does not emit telemetry when model resolution fails" do
      {:ok, request} = EvaluationRequest.new(nil, "state", questions())
      assert {:error, _} = EvaluationPipeline.call(request)

      refute_received {:telemetry_event, [:sycophant, :evaluation, :start], _, _}
    end
  end
end
