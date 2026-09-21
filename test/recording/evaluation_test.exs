defmodule Sycophant.Recording.EvaluationTest do
  @moduledoc """
  Recording coverage for `Sycophant.evaluate/4` against both evaluation routes.

  `config :sycophant, :test_evaluation_models` is empty until each model's
  fixture is committed, because CI runs `mix test.recording` and a listed
  model with no fixture fails the build. Add a model back to that config list
  only together with its committed fixture.

  To record the missing fixtures, set `TYPESAFE_API_KEY` and
  `OPENROUTER_API_KEY`, add both entries back to
  `:test_evaluation_models` in `config/test.exs`:

      %{model: "typesafe:jev-latest"},
      %{model: "openrouter:typesafe/jev-1.13"}

  then run, scoped to this file (the `mix test.recording <file>` alias form
  runs the whole `test/recording/` directory, not just this file, since the
  alias already carries its own `test/recording/` path argument):

      RECORD=true mix test --include recording test/recording/evaluation_test.exs

  This writes:

      priv/fixtures/recordings/typesafe/jev-latest/evaluates_choice_score_and_boolean_questions.json
      priv/fixtures/recordings/openrouter/typesafe/jev-1.13/evaluates_choice_score_and_boolean_questions.json

  Before committing, confirm every `authorization` header value in both
  files is `"[REDACTED]"` and that grepping them for the literal API key
  values finds nothing.
  """

  @models Sycophant.RecordingCase.test_evaluation_models()
  use Sycophant.RecordingCase, async: true, parameterize: @models

  @questions %{
    department: %{
      type: :choice,
      instructions: "Which team should handle this ticket?",
      criteria: %{billing: "Billing and payments", support: "Technical support"}
    },
    severity: %{
      type: :score,
      instructions: "Rate the severity of this ticket from 1 to 5",
      criteria: ["1 - trivial", "2 - minor", "3 - moderate", "4 - major", "5 - critical"]
    },
    urgent: %{type: :boolean, instructions: "Does this need immediate attention?"}
  }

  @tag recording_prefix: true
  test "evaluates choice, score, and boolean questions", %{model: model} do
    assert {:ok, res} =
             Sycophant.evaluate(
               model,
               %{ticket: "Please refund me today, this is the third time I ask"},
               @questions,
               recording_opts([])
             )

    assert res.answers.department.type == :choice
    assert res.answers.department.value in ["billing", "support"]

    assert res.answers.severity.type == :score
    assert is_float(res.answers.severity.value)

    assert res.answers.urgent.type == :boolean
    assert res.answers.urgent.probability >= 0.0
    assert res.answers.urgent.probability <= 1.0

    assert res.usage.input_tokens > 0

    if String.starts_with?(model, "openrouter:") do
      assert is_float(res.usage.total_cost)
    end
  end
end
