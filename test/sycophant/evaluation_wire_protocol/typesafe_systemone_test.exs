defmodule Sycophant.EvaluationWireProtocol.TypesafeSystemoneTest do
  use ExUnit.Case, async: true

  alias Sycophant.EvaluationAnswer
  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationWireProtocol.TypesafeSystemone

  @fixture %{
    "model" => "jev-1.13.0",
    "answers" => %{
      "urgent" => %{"type" => "noul", "noul" => 0.93},
      "department" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.88, "support" => 0.12},
        "confidence" => 0.81
      },
      "severity" => %{
        "type" => "score",
        "score" => 1.05,
        "legend" => %{"0" => "low", "1" => "medium", "2" => "high"},
        "probabilities" => %{"0" => 0.0, "1" => 0.95, "2" => 0.05},
        "confidence" => 0.92
      }
    },
    "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
  }

  describe "request_path/1" do
    test "returns the systemone path" do
      {:ok, request} = EvaluationRequest.new("jev-latest", "state", %{urgent: boolean_question()})
      assert TypesafeSystemone.request_path(request) == "/v1/systemone"
    end
  end

  describe "encode_request/1" do
    test "encodes atom-keyed questions of all three types with no atom keys or values" do
      questions = %{
        urgent: boolean_question(),
        department: %{
          type: :choice,
          instructions: "Which department should handle this?",
          criteria: %{billing: "Billing questions", support: "Support questions"}
        },
        severity: %{
          type: :score,
          instructions: "How severe is this issue?",
          criteria: ["low", "medium", "high"]
        }
      }

      {:ok, request} =
        EvaluationRequest.new("jev-latest", "the conversation transcript", questions)

      expected = %{
        "model" => "jev-latest",
        "state" => "the conversation transcript",
        "questions" => %{
          "urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"},
          "department" => %{
            "type" => "choice",
            "instructions" => "Which department should handle this?",
            "criteria" => %{"billing" => "Billing questions", "support" => "Support questions"}
          },
          "severity" => %{
            "type" => "score",
            "instructions" => "How severe is this issue?",
            "criteria" => ["low", "medium", "high"]
          }
        }
      }

      assert {:ok, payload} = TypesafeSystemone.encode_request(request)
      assert payload == expected
      assert JSON.decode!(JSON.encode!(payload)) == payload
    end

    test "stringifies boolean criteria keys" do
      questions = %{
        urgent: %{
          type: :boolean,
          instructions: "Is this urgent?",
          criteria: %{true: "yes means urgent", false: "no means not urgent"}
        }
      }

      {:ok, request} = EvaluationRequest.new("jev-latest", "state", questions)
      assert {:ok, payload} = TypesafeSystemone.encode_request(request)

      assert payload["questions"]["urgent"]["criteria"] == %{
               "true" => "yes means urgent",
               "false" => "no means not urgent"
             }
    end
  end

  describe "decode_response/2" do
    test "decodes fixture answers, usage, and raw body" do
      assert {:ok, response} = TypesafeSystemone.decode_response(@fixture, [])
      assert response.model == "jev-1.13.0"
      assert response.raw == @fixture

      assert response.answers["urgent"] == %EvaluationAnswer{type: :boolean, probability: 0.93}

      assert response.answers["department"] == %EvaluationAnswer{
               type: :choice,
               value: "billing",
               probabilities: %{"billing" => 0.88, "support" => 0.12},
               confidence: 0.81
             }

      assert response.answers["severity"] == %EvaluationAnswer{
               type: :score,
               value: 1.05,
               legend: %{"0" => "low", "1" => "medium", "2" => "high"},
               probabilities: %{"0" => 0.0, "1" => 0.95, "2" => 0.05},
               confidence: 0.92
             }

      assert response.usage.input_tokens == 100
      assert response.usage.output_tokens == 20
      assert response.usage.total_cost == nil
    end

    test "decodes usage cost when present" do
      fixture = put_in(@fixture["usage"]["cost"], 0.0000042)
      assert {:ok, response} = TypesafeSystemone.decode_response(fixture, [])
      assert response.usage.total_cost == 0.0000042
    end

    test "errors when answers key is missing" do
      body = Map.delete(@fixture, "answers")

      assert {:error, %Sycophant.Error.Provider.ResponseInvalid{}} =
               TypesafeSystemone.decode_response(body, [])
    end

    test "errors on an answer with an unknown type" do
      body = put_in(@fixture["answers"]["urgent"], %{"type" => "ranking"})

      assert {:error, %Sycophant.Error.Provider.ResponseInvalid{}} =
               TypesafeSystemone.decode_response(body, [])
    end

    test "errors on a known type missing its value field" do
      body = put_in(@fixture["answers"]["urgent"], %{"type" => "noul"})

      assert {:error, %Sycophant.Error.Provider.ResponseInvalid{}} =
               TypesafeSystemone.decode_response(body, [])
    end

    test "decodes an integer zero cost as a float" do
      fixture = put_in(@fixture["usage"]["cost"], 0)
      assert {:ok, response} = TypesafeSystemone.decode_response(fixture, [])
      assert response.usage.total_cost === 0.0
    end

    test "treats a non-numeric cost as nil instead of raising" do
      fixture = put_in(@fixture["usage"]["cost"], "free")
      assert {:ok, response} = TypesafeSystemone.decode_response(fixture, [])
      assert response.usage.total_cost == nil
    end
  end

  defp boolean_question, do: %{type: :boolean, instructions: "Is this urgent?"}
end
