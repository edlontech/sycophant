defmodule Sycophant.EvaluationWireProtocol.OpenAIDecisionsTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidParams
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.EvaluationAnswer
  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationWireProtocol.OpenAIDecisions

  @questions %{
    urgent: %{type: :boolean, instructions: "Is it urgent?"},
    department: %{
      type: :choice,
      instructions: "Which team?",
      criteria: %{support: "Technical support", billing: "Billing and payments"}
    },
    severity: %{
      type: :score,
      instructions: "How severe?",
      criteria: ["low", "medium", "high"]
    }
  }

  describe "encode_request/1" do
    test "encodes all three question types as a name-sorted list" do
      {:ok, request} = EvaluationRequest.new("gpt-6-luna", "ticket text", @questions)

      assert {:ok, body} = OpenAIDecisions.encode_request(request)

      assert body == %{
               "model" => "gpt-6-luna",
               "input" => "ticket text",
               "questions" => [
                 %{
                   "name" => "department",
                   "type" => "choice",
                   "instructions" => "Which team?",
                   "choices" => [
                     %{"value" => "billing", "description" => "Billing and payments"},
                     %{"value" => "support", "description" => "Technical support"}
                   ]
                 },
                 %{
                   "name" => "severity",
                   "type" => "score",
                   "instructions" => "How severe?",
                   "levels" => [%{"label" => "low"}, %{"label" => "medium"}, %{"label" => "high"}]
                 },
                 %{"name" => "urgent", "type" => "predicate", "instructions" => "Is it urgent?"}
               ]
             }
    end

    test "JSON-encodes a non-string state and includes safety_identifier" do
      {:ok, request} =
        EvaluationRequest.new("gpt-6-luna", %{ticket: "Refund me"}, @questions,
          safety_identifier: "user-1"
        )

      assert {:ok, body} = OpenAIDecisions.encode_request(request)
      assert body["input"] == ~s({"ticket":"Refund me"})
      assert body["safety_identifier"] == "user-1"
    end

    test "rejects safety_identifier longer than 128 characters" do
      {:ok, request} =
        EvaluationRequest.new("gpt-6-luna", "text", @questions,
          safety_identifier: String.duplicate("a", 129)
        )

      assert {:error, %InvalidParams{}} = OpenAIDecisions.encode_request(request)
    end

    test "rejects non-string instructions, descriptions, and labels" do
      for question <- [
            %{type: :boolean, instructions: %{text: "Is it urgent?"}},
            %{type: :choice, instructions: "Which?", criteria: %{a: ["desc"]}},
            %{type: :score, instructions: "How?", criteria: [%{label: "low"}]}
          ] do
        {:ok, request} = EvaluationRequest.new("gpt-6-luna", "text", %{q: question})

        assert {:error, %InvalidParams{errors: [message]}} =
                 OpenAIDecisions.encode_request(request)

        assert message =~ "q"
      end
    end

    test "rejects boolean questions with criteria" do
      {:ok, request} =
        EvaluationRequest.new("gpt-6-luna", "text", %{
          q: %{type: :boolean, instructions: "Urgent?", criteria: %{true: "yes", false: "no"}}
        })

      assert {:error, %InvalidParams{}} = OpenAIDecisions.encode_request(request)
    end
  end

  @answers [
    %{
      "name" => "department",
      "type" => "choice",
      "choice" => "billing",
      "confidence" => 0.8,
      "probabilities" => [
        %{"value" => "billing", "probability" => 0.8},
        %{"value" => "support", "probability" => 0.2}
      ]
    },
    %{
      "name" => "severity",
      "type" => "score",
      "score" => 1.1,
      "confidence" => 0.7,
      "probabilities" => [
        %{"label" => "low", "value" => 0, "probability" => 0.1},
        %{"label" => "medium", "value" => 1, "probability" => 0.7},
        %{"label" => "high", "value" => 2, "probability" => 0.2}
      ]
    },
    %{"name" => "urgent", "type" => "predicate", "probability" => 0.75}
  ]

  @body %{
    "id" => "dec_123",
    "model" => "gpt-6-luna",
    "answers" => @answers,
    "usage" => %{"input_tokens" => 8, "output_tokens" => 3}
  }

  describe "decode_response/3" do
    setup do
      {:ok, request} = EvaluationRequest.new("gpt-6-luna", "ticket text", @questions)
      %{request: request}
    end

    test "decodes answers keyed by name into the shared EvaluationAnswer shape", %{
      request: request
    } do
      assert {:ok, response} = OpenAIDecisions.decode_response(@body, [], request)

      assert response.model == "gpt-6-luna"
      assert response.usage == %Sycophant.Usage{input_tokens: 8, output_tokens: 3}
      assert response.raw == @body

      assert response.answers["urgent"] == %EvaluationAnswer{type: :boolean, probability: 0.75}

      assert response.answers["department"] == %EvaluationAnswer{
               type: :choice,
               value: "billing",
               confidence: 0.8,
               probabilities: %{"billing" => 0.8, "support" => 0.2}
             }

      assert response.answers["severity"] == %EvaluationAnswer{
               type: :score,
               value: 1.1,
               confidence: 0.7,
               legend: %{"0" => "low", "1" => "medium", "2" => "high"},
               probabilities: %{"0" => 0.1, "1" => 0.7, "2" => 0.2}
             }
    end

    test "decodes a refusal without failing the other answers", %{request: request} do
      [department, _severity, urgent] = @answers
      refusal = %{"name" => "severity", "type" => "refusal", "reason" => "policy"}
      body = %{@body | "answers" => [department, refusal, urgent]}

      assert {:ok, response} = OpenAIDecisions.decode_response(body, [], request)

      assert response.answers["severity"] == %EvaluationAnswer{type: :refusal, reason: "policy"}
      assert response.answers["urgent"].type == :boolean
    end

    test "rejects answers that do not match the request contract", %{request: request} do
      [department, severity, urgent] = @answers

      mismatches = [
        missing_answer: [department, severity],
        out_of_order: [severity, department, urgent],
        wrong_type: [department, severity, %{urgent | "type" => "choice"}],
        unknown_choice: [%{department | "choice" => "legal"}, severity, urgent],
        wrong_choice_set: [
          %{department | "probabilities" => [%{"value" => "billing", "probability" => 1.0}]},
          severity,
          urgent
        ],
        wrong_levels: [
          department,
          %{severity | "probabilities" => Enum.reverse(severity["probabilities"])},
          urgent
        ],
        score_out_of_range: [department, %{severity | "score" => 2.5}, urgent],
        probability_out_of_range: [department, severity, %{urgent | "probability" => 1.5}]
      ]

      for {case_name, answers} <- mismatches do
        assert {:error, %ResponseInvalid{}} =
                 OpenAIDecisions.decode_response(%{@body | "answers" => answers}, [], request),
               "expected #{case_name} to be rejected"
      end
    end

    test "rejects a body without the expected top-level fields", %{request: request} do
      assert {:error, %ResponseInvalid{}} =
               OpenAIDecisions.decode_response(%{"error" => "nope"}, [], request)
    end
  end
end
