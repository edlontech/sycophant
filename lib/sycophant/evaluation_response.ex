defmodule Sycophant.EvaluationResponse do
  @moduledoc """
  The result of an evaluation request.

  Answers are keyed by the name of the evaluated criterion (e.g. `"urgent"`),
  with each value a `Sycophant.EvaluationAnswer`.

  ## Examples

      {:ok, response} = Sycophant.evaluate(request)

      response.answers["urgent"].type
      #=> :boolean
      response.answers["urgent"].probability
      #=> 0.93
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("EvaluationResponse") |> Zoi.default("EvaluationResponse"),
            answers: Zoi.default(Zoi.any(), %{}),
            model: Zoi.optional(Zoi.string()),
            usage: Zoi.optional(Sycophant.Usage.t()),
            raw: Zoi.optional(Zoi.any())

  @doc false
  @spec decode(map()) :: t()
  def decode(data) do
    resp = Zoi.parse!(__MODULE__.t(), Map.delete(data, "answers"))
    %{resp | answers: decode_answers(data["answers"])}
  end

  defp decode_answers(nil), do: %{}

  defp decode_answers(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, Zoi.parse!(Sycophant.EvaluationAnswer.t(), v)}
    end)
  end
end

defimpl Inspect, for: Sycophant.EvaluationResponse do
  import Inspect.Algebra

  def inspect(resp, opts) do
    fields =
      Enum.reject(
        [
          model: resp.model,
          answers: Map.keys(resp.answers),
          usage: resp.usage
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.EvaluationResponse<", to_doc(Map.new(fields), opts), ">"])
  end
end
