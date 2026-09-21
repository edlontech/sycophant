defmodule Sycophant.EvaluationWireProtocol.TypesafeSystemone do
  @moduledoc """
  Wire protocol adapter for the TypeSafe System One evaluation API.

  Translates a canonical `EvaluationRequest` into TypeSafe's JSON format and
  normalizes responses back into an `EvaluationResponse`. Answers are decoded
  keyed by their string id; re-keying to the caller's original question keys
  happens later in the pipeline.
  """

  @behaviour Sycophant.EvaluationWireProtocol

  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.EvaluationAnswer
  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationResponse
  alias Sycophant.Usage

  @impl true
  def request_path(_request), do: "/v1/systemone"

  @impl true
  def encode_request(%EvaluationRequest{} = request) do
    questions =
      Map.new(request.questions, fn {key, question} ->
        {to_string(key), encode_question(question)}
      end)

    {:ok, %{"model" => request.model, "state" => request.state, "questions" => questions}}
  end

  @impl true
  def decode_response(
        %{"model" => model, "answers" => answers, "usage" => usage} = body,
        _headers
      )
      when is_binary(model) and is_map(answers) and is_map(usage) do
    case decode_answers(answers) do
      {:ok, decoded} ->
        {:ok,
         %EvaluationResponse{
           answers: decoded,
           model: model,
           usage: decode_usage(usage),
           raw: body
         }}

      :error ->
        {:error, ResponseInvalid.exception(raw: body)}
    end
  end

  def decode_response(body, _headers) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  defp encode_question(question) do
    put_criteria(
      %{"type" => wire_type(question.type), "instructions" => question.instructions},
      question
    )
  end

  defp wire_type(:boolean), do: "noul"
  defp wire_type(:choice), do: "choice"
  defp wire_type(:score), do: "score"

  defp put_criteria(encoded, question) do
    case Map.get(question, :criteria) do
      nil -> encoded
      criteria -> Map.put(encoded, "criteria", stringify_criteria(criteria))
    end
  end

  defp stringify_criteria(criteria) when is_map(criteria) do
    Map.new(criteria, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_criteria(criteria), do: criteria

  defp decode_answers(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case decode_answer(answer) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, id, decoded)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_answer(%{"type" => "noul", "noul" => probability}) do
    {:ok, %EvaluationAnswer{type: :boolean, probability: probability}}
  end

  defp decode_answer(%{"type" => "choice", "choice" => value} = answer) do
    {:ok,
     %EvaluationAnswer{
       type: :choice,
       value: value,
       probabilities: Map.get(answer, "probabilities"),
       confidence: Map.get(answer, "confidence")
     }}
  end

  defp decode_answer(%{"type" => "score", "score" => value} = answer) do
    {:ok,
     %EvaluationAnswer{
       type: :score,
       value: value,
       legend: Map.get(answer, "legend"),
       probabilities: Map.get(answer, "probabilities"),
       confidence: Map.get(answer, "confidence")
     }}
  end

  defp decode_answer(_answer), do: :error

  defp decode_usage(usage) do
    %Usage{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      total_cost: normalize_cost(usage["cost"])
    }
  end

  defp normalize_cost(cost) when is_number(cost), do: cost * 1.0
  defp normalize_cost(_cost), do: nil
end
