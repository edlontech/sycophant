defmodule Sycophant.EvaluationWireProtocol.OpenRouterDecisionsTest do
  use ExUnit.Case, async: true

  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationWireProtocol.OpenRouterDecisions
  alias Sycophant.EvaluationWireProtocol.TypesafeSystemone

  describe "request_path/1" do
    test "returns the alpha decisions path" do
      {:ok, request} =
        EvaluationRequest.new("typesafe/jev-1.13", "state", %{
          urgent: %{type: :boolean, instructions: "Is this urgent?"}
        })

      assert OpenRouterDecisions.request_path(request) == "/api/alpha/decisions"
    end
  end

  describe "encode_request/1" do
    test "returns the same payload as TypesafeSystemone for the same request" do
      questions = %{
        urgent: %{type: :boolean, instructions: "Is this urgent?"},
        severity: %{
          type: :score,
          instructions: "How severe is this issue?",
          criteria: ["low", "medium", "high"]
        }
      }

      {:ok, request} = EvaluationRequest.new("typesafe/jev-1.13", "state", questions)

      assert OpenRouterDecisions.encode_request(request) ==
               TypesafeSystemone.encode_request(request)
    end
  end

  describe "decode_response/2" do
    test "maps a billed cost into usage.total_cost, delegating to TypesafeSystemone" do
      body = %{
        "model" => "jev-1.13.0",
        "answers" => %{
          "urgent" => %{"type" => "noul", "noul" => 0.93}
        },
        "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.0000042}
      }

      assert {:ok, response} = OpenRouterDecisions.decode_response(body, [])
      assert response.usage.total_cost == 0.0000042
    end
  end
end
