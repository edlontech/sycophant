defmodule Sycophant.EvaluationAnswer do
  @moduledoc """
  A single answer produced by an evaluation model.

  The `type` determines which of the other fields are meaningful:

    * `:boolean` - a yes/no judgment, typically with `probability`.
    * `:choice` - a selection among labeled options, typically with
      `probabilities` mapping each option to its likelihood.
    * `:score` - a numeric rating, typically with `confidence` and a
      `legend` describing what each value on the scale means.
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("EvaluationAnswer") |> Zoi.default("EvaluationAnswer"),
            type: Zoi.enum([boolean: "boolean", choice: "choice", score: "score"], coerce: true),
            value: Zoi.union([Zoi.string(), Zoi.number()]) |> Zoi.optional(),
            probability: Zoi.optional(Zoi.number()),
            probabilities: Zoi.map(Zoi.string(), Zoi.number()) |> Zoi.optional(),
            confidence: Zoi.optional(Zoi.number()),
            legend: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.optional()
end
