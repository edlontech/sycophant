defmodule Sycophant.EvaluationRequestTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidParams
  alias Sycophant.EvaluationRequest
  alias Sycophant.Usage

  @model "openai:gpt-4"

  describe "new/3 accepts valid input" do
    test "boolean question without criteria" do
      assert {:ok, %EvaluationRequest{} = req} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })

      assert req.questions.q1.type == :boolean
    end

    test "boolean question with true/false criteria" do
      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{
                   type: :boolean,
                   instructions: "Is this correct?",
                   criteria: %{true: "meets the bar", false: "does not meet the bar"}
                 }
               })
    end

    test "choice question with string criteria values, keyed by string id" do
      assert {:ok, %EvaluationRequest{questions: questions}} =
               EvaluationRequest.new(@model, "transcript", %{
                 "q1" => %{
                   type: :choice,
                   instructions: "Pick one",
                   criteria: %{good: "Good answer", bad: "Bad answer"}
                 }
               })

      assert Map.has_key?(questions, "q1")
    end

    test "choice question whose criteria values are maps" do
      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{
                   type: :choice,
                   instructions: "Pick one",
                   criteria: %{good: %{description: "Good answer", weight: 1}}
                 }
               })
    end

    test "score question with list criteria" do
      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :score, instructions: "Rate it", criteria: ["poor", "fair", "great"]}
               })
    end

    test "accepts a map state" do
      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, %{turns: []}, %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })
    end

    test "accepts a list state" do
      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, [%{role: "user", content: "hi"}], %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })
    end

    test "does not enforce provider limits on choice count or score levels" do
      choices = for i <- 1..300, into: %{}, do: {"choice_#{i}", "option #{i}"}

      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 many: %{type: :choice, instructions: "Pick one", criteria: choices}
               })

      assert {:ok, %EvaluationRequest{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 one_level: %{type: :score, instructions: "Rate it", criteria: ["only level"]}
               })
    end
  end

  describe "new/3 rejects invalid input" do
    test "integer state" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, 42, %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })
    end

    test "empty questions" do
      assert {:error, %InvalidParams{}} = EvaluationRequest.new(@model, "transcript", %{})
    end

    test "non-map questions" do
      assert {:error, %InvalidParams{}} = EvaluationRequest.new(@model, "transcript", [])
    end

    test "unknown question type" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :ranking, instructions: "Rank it"}
               })
    end

    test "question missing instructions" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{q1: %{type: :boolean}})
    end

    test "choice question with list criteria" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :choice, instructions: "Pick one", criteria: ["a", "b"]}
               })
    end

    test "score question with map criteria" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :score, instructions: "Rate it", criteria: %{low: "bad"}}
               })
    end

    test "question keys that collide once stringified" do
      question = %{type: :boolean, instructions: "Is this correct?"}

      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{"a" => question, a: question})
    end

    test "a struct with no JSON.Encoder impl inside state returns an error, does not raise" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, %{at: %Usage{input_tokens: 1}}, %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })
    end

    test "a tuple inside state returns an error, does not raise" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, %{at: {1, 2}}, %{
                 q1: %{type: :boolean, instructions: "Is this correct?"}
               })
    end

    test "unknown extra key in a question" do
      assert {:error, %InvalidParams{}} =
               EvaluationRequest.new(@model, "transcript", %{
                 q1: %{type: :boolean, instructions: "Is this correct?", bogus: "nope"}
               })
    end
  end
end
