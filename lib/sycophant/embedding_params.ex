defmodule Sycophant.EmbeddingParams do
  @moduledoc """
  Canonical embedding parameters with Zoi validation.

  All fields are optional. Wire protocol adapters translate these into
  provider-specific parameter names and value formats.

  ## Supported Parameters

    * `:dimensions` - Desired output vector dimensionality (positive integer)
    * `:embedding_types` - List of output types (`:float`, `:int8`, `:uint8`, `:binary`, `:ubinary`). Defaults to `[:float]`
    * `:truncate` - Truncation strategy (`:none`, `:left`, `:right`). Defaults to `:none`
    * `:max_tokens` - Maximum tokens to embed per input (positive integer)
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("EmbeddingParams") |> Zoi.default("EmbeddingParams"),
            dimensions: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            embedding_types:
              Zoi.list(
                Zoi.enum(
                  [
                    float: "float",
                    int8: "int8",
                    uint8: "uint8",
                    binary: "binary",
                    ubinary: "ubinary"
                  ],
                  coerce: true
                )
              )
              |> Zoi.default([:float]),
            truncate:
              Zoi.enum([none: "none", left: "left", right: "right"], coerce: true)
              |> Zoi.default(:none),
            max_tokens: Zoi.integer() |> Zoi.positive() |> Zoi.optional()
end

defimpl Inspect, for: Sycophant.EmbeddingParams do
  import Inspect.Algebra

  def inspect(params, opts) do
    fields =
      Enum.reject(
        [
          dimensions: params.dimensions,
          embedding_types: params.embedding_types,
          truncate: params.truncate,
          max_tokens: params.max_tokens
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.EmbeddingParams<", to_doc(Map.new(fields), opts), ">"])
  end
end
