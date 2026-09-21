defmodule Sycophant.EvaluationResponseTest do
  use ExUnit.Case, async: true

  alias Sycophant.EvaluationAnswer
  alias Sycophant.EvaluationResponse
  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder
  alias Sycophant.Usage

  describe "to_map/1" do
    test "encodes a response with atom answer keys without raising" do
      resp = %EvaluationResponse{
        answers: %{urgent: %EvaluationAnswer{type: :boolean, probability: 0.93}},
        model: "anthropic:claude-haiku-4-5"
      }

      map = Serializable.to_map(resp)

      assert map["__type__"] == "EvaluationResponse"
      assert map["answers"]["urgent"]["type"] == "boolean"
      assert map["answers"]["urgent"]["probability"] == 0.93
    end
  end

  describe "serialization round-trip" do
    test "decodes with string answer keys, atom type, and preserved fields" do
      original = %EvaluationResponse{
        answers: %{urgent: %EvaluationAnswer{type: :boolean, probability: 0.93}},
        model: "anthropic:claude-haiku-4-5",
        usage: %Usage{input_tokens: 10, output_tokens: 5}
      }

      restored = original |> Decoder.encode() |> Decoder.decode()

      assert Map.keys(restored.answers) == ["urgent"]
      assert restored.answers["urgent"].type == :boolean
      assert restored.answers["urgent"].probability == 0.93
      assert %Usage{input_tokens: 10, output_tokens: 5} = restored.usage
    end

    test "round-trips all three answer types" do
      original = %EvaluationResponse{
        answers: %{
          is_spam: %EvaluationAnswer{type: :boolean, probability: 0.99},
          category: %EvaluationAnswer{
            type: :choice,
            value: "refund",
            probabilities: %{"refund" => 0.7, "cancel" => 0.3}
          },
          quality: %EvaluationAnswer{
            type: :score,
            value: 4,
            confidence: 0.8,
            legend: %{"1" => "poor", "5" => "excellent"}
          }
        }
      }

      restored = original |> Decoder.encode() |> Decoder.decode()

      assert restored.answers["is_spam"] == %EvaluationAnswer{
               type: :boolean,
               probability: 0.99
             }

      assert restored.answers["category"] == %EvaluationAnswer{
               type: :choice,
               value: "refund",
               probabilities: %{"refund" => 0.7, "cancel" => 0.3}
             }

      assert restored.answers["quality"] == %EvaluationAnswer{
               type: :score,
               value: 4,
               confidence: 0.8,
               legend: %{"1" => "poor", "5" => "excellent"}
             }
    end
  end

  describe "Inspect" do
    test "shows model, answer keys, and usage but never raw" do
      resp = %EvaluationResponse{
        answers: %{urgent: %EvaluationAnswer{type: :boolean, probability: 0.93}},
        model: "anthropic:claude-haiku-4-5",
        usage: %Usage{input_tokens: 10},
        raw: %{"secret" => "do-not-print"}
      }

      output = inspect(resp)

      assert String.starts_with?(output, "#Sycophant.EvaluationResponse<")
      refute output =~ "do-not-print"
      refute output =~ "secret"
    end
  end
end
