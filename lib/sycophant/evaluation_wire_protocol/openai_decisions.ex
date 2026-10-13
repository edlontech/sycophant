defmodule Sycophant.EvaluationWireProtocol.OpenAIDecisions do
  @moduledoc """
  Wire protocol adapter for OpenAI's Decisions API (`POST /decisions`).

  Translates a canonical `EvaluationRequest` into OpenAI's positional
  format: `state` becomes the string `input` (JSON-encoded when it is a map
  or list), and `questions` become a list sorted by stringified key, with
  `:boolean` sent as `predicate`, `:choice` criteria as `choices`, and
  `:score` criteria as `levels`. OpenAI only accepts string instructions,
  descriptions, and labels, and has no predicate criteria, so those shapes
  are rejected with `InvalidParams` rather than reinterpreted.

  Answers come back as a list in request order. `decode_response/3`
  rebuilds the expected question list from the request and rejects any
  response whose answers do not match it in count, order, type, or
  allowed values. Decoded answers use the same `EvaluationAnswer` shape as
  `Sycophant.EvaluationWireProtocol.TypesafeSystemone`, so callers see one
  shape regardless of provider. A per-question `refusal` decodes to a
  `:refusal` answer.
  """

  @behaviour Sycophant.EvaluationWireProtocol

  alias Sycophant.Error.Invalid.InvalidParams
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.EvaluationAnswer
  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationResponse
  alias Sycophant.Usage

  @impl true
  def request_path(_request), do: "/decisions"

  @impl true
  def encode_request(%EvaluationRequest{} = request) do
    with :ok <- validate_safety_identifier(request.safety_identifier),
         {:ok, questions} <- encode_questions(request.questions) do
      body = %{
        "model" => request.model,
        "input" => encode_input(request.state),
        "questions" => questions
      }

      {:ok, put_safety_identifier(body, request.safety_identifier)}
    end
  end

  @impl true
  def decode_response(
        %{"model" => model, "answers" => answers, "usage" => usage} = body,
        _headers,
        %EvaluationRequest{} = request
      )
      when is_binary(model) and is_list(answers) and is_map(usage) do
    with {:ok, expected} <- encode_questions(request.questions),
         {:ok, decoded} <- decode_answers(answers, expected) do
      {:ok,
       %EvaluationResponse{
         answers: decoded,
         model: model,
         usage: %Usage{input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]},
         raw: body
       }}
    else
      {:error, %InvalidParams{errors: errors}} -> invalid_response(body, errors)
      {:error, message} -> invalid_response(body, [message])
    end
  end

  def decode_response(body, _headers, _request) do
    invalid_response(body, ["expected model, answers list, and usage"])
  end

  defp invalid_response(body, errors) do
    {:error, ResponseInvalid.exception(raw: body, errors: errors)}
  end

  defp decode_answers(answers, expected) when length(answers) != length(expected) do
    {:error, "expected #{length(expected)} answers, got #{length(answers)}"}
  end

  defp decode_answers(answers, expected) do
    answers
    |> Enum.zip(expected)
    |> Enum.reduce_while({:ok, %{}}, fn {answer, question}, {:ok, acc} ->
      case decode_answer(answer, question) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, question["name"], decoded)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp decode_answer(%{"name" => name}, %{"name" => expected}) when name != expected do
    {:error, "answer #{inspect(name)} is out of order, expected #{inspect(expected)}"}
  end

  defp decode_answer(%{"type" => "refusal"} = answer, _question) do
    {:ok, %EvaluationAnswer{type: :refusal, reason: answer["reason"]}}
  end

  defp decode_answer(%{"type" => "predicate", "probability" => p}, %{"type" => "predicate"})
       when is_number(p) and p >= 0 and p <= 1 do
    {:ok, %EvaluationAnswer{type: :boolean, probability: p}}
  end

  defp decode_answer(
         %{"type" => "choice", "choice" => choice, "probabilities" => probabilities} = answer,
         %{"type" => "choice", "choices" => choices}
       )
       when is_list(probabilities) do
    allowed = Enum.map(choices, & &1["value"])
    values = Enum.map(probabilities, &to_string(&1["value"]))
    choice = to_string(choice)

    if choice in allowed and Enum.sort(values) == allowed do
      {:ok,
       %EvaluationAnswer{
         type: :choice,
         value: choice,
         confidence: answer["confidence"],
         probabilities: Map.new(probabilities, &{to_string(&1["value"]), &1["probability"]})
       }}
    else
      {:error, "choice answer #{inspect(answer["name"])} does not match the requested choices"}
    end
  end

  defp decode_answer(
         %{"type" => "score", "score" => score, "probabilities" => probabilities} = answer,
         %{"type" => "score", "levels" => levels}
       )
       when is_number(score) and is_list(probabilities) do
    labels = Enum.map(levels, & &1["label"])
    expected_values = Enum.to_list(0..(length(labels) - 1))

    if Enum.map(probabilities, & &1["label"]) == labels and
         Enum.map(probabilities, & &1["value"]) == expected_values and
         score >= 0 and score <= length(labels) - 1 do
      {:ok,
       %EvaluationAnswer{
         type: :score,
         value: score,
         confidence: answer["confidence"],
         legend: Map.new(probabilities, &{to_string(&1["value"]), &1["label"]}),
         probabilities: Map.new(probabilities, &{to_string(&1["value"]), &1["probability"]})
       }}
    else
      {:error, "score answer #{inspect(answer["name"])} does not match the requested levels"}
    end
  end

  defp decode_answer(answer, question) do
    {:error,
     "answer #{inspect(question["name"])} is malformed or its type does not match the request " <>
       "(#{inspect(answer["type"])} vs #{inspect(question["type"])})"}
  end

  defp validate_safety_identifier(nil), do: :ok

  defp validate_safety_identifier(value) when is_binary(value) do
    if String.length(value) <= 128,
      do: :ok,
      else: invalid_params("safety_identifier must be at most 128 characters")
  end

  defp put_safety_identifier(body, nil), do: body
  defp put_safety_identifier(body, value), do: Map.put(body, "safety_identifier", value)

  defp encode_input(state) when is_binary(state), do: state
  defp encode_input(state), do: JSON.encode!(state)

  defp encode_questions(questions) do
    questions
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.reduce_while({:ok, []}, fn {key, question}, {:ok, acc} ->
      case encode_question(to_string(key), question) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_question(name, %{instructions: instructions})
       when not is_binary(instructions) do
    invalid_params("question #{inspect(name)}: OpenAI Decisions requires string instructions")
  end

  defp encode_question(name, %{type: :boolean, criteria: _}) do
    invalid_params(
      "question #{inspect(name)}: OpenAI Decisions boolean questions take no criteria"
    )
  end

  defp encode_question(name, %{type: :boolean, instructions: instructions}) do
    {:ok, %{"name" => name, "type" => "predicate", "instructions" => instructions}}
  end

  defp encode_question(name, %{type: :choice, instructions: instructions, criteria: criteria}) do
    if Enum.all?(criteria, fn {_value, description} -> is_binary(description) end) do
      choices =
        criteria
        |> Enum.map(fn {value, description} ->
          %{"value" => to_string(value), "description" => description}
        end)
        |> Enum.sort_by(& &1["value"])

      {:ok,
       %{"name" => name, "type" => "choice", "instructions" => instructions, "choices" => choices}}
    else
      invalid_params(
        "question #{inspect(name)}: OpenAI Decisions requires string choice descriptions"
      )
    end
  end

  defp encode_question(name, %{type: :score, instructions: instructions, criteria: criteria}) do
    if Enum.all?(criteria, &is_binary/1) do
      levels = Enum.map(criteria, &%{"label" => &1})

      {:ok,
       %{"name" => name, "type" => "score", "instructions" => instructions, "levels" => levels}}
    else
      invalid_params("question #{inspect(name)}: OpenAI Decisions requires string score labels")
    end
  end

  defp invalid_params(message), do: {:error, InvalidParams.exception(errors: [message])}
end
