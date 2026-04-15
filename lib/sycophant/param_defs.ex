defmodule Sycophant.ParamDefs do
  @moduledoc """
  Shared Zoi schema fragments for LLM parameters.

  Returns a map of common parameter definitions suitable for composing
  into `Zoi.object/1` schemas. Wire protocol adapters can merge these
  with protocol-specific params before building their validation schema.
  """

  @doc """
  Returns a map of shared parameter Zoi schemas keyed by atom name.

  All params are optional. The map can be passed directly to `Zoi.object/1`
  or merged with wire-specific extras via `Map.merge/2`.
  """
  @spec shared() :: map()
  def shared do
    %{
      temperature:
        Zoi.float(description: "Sampling temperature")
        |> Zoi.min(0.0)
        |> Zoi.max(2.0)
        |> Zoi.optional(),
      max_tokens:
        Zoi.integer(description: "Maximum number of tokens to generate")
        |> Zoi.positive()
        |> Zoi.optional(),
      top_p:
        Zoi.float(description: "Nucleus sampling threshold")
        |> Zoi.min(0.0)
        |> Zoi.max(1.0)
        |> Zoi.optional(),
      top_k:
        Zoi.integer(description: "Top-K sampling")
        |> Zoi.positive()
        |> Zoi.optional(),
      stop:
        Zoi.list(Zoi.string(), description: "Stop sequences")
        |> Zoi.optional(),
      reasoning_effort:
        Zoi.enum([:none, :minimal, :low, :medium, :high, :xhigh],
          description: "Extended thinking effort level"
        )
        |> Zoi.optional(),
      reasoning_summary:
        Zoi.enum([:auto, :concise, :detailed, :none],
          description: "How to summarize reasoning"
        )
        |> Zoi.optional(),
      service_tier:
        Zoi.string(description: "Service tier selection")
        |> Zoi.optional(),
      tool_choice:
        Zoi.any(description: "Tool selection strategy")
        |> Zoi.optional(),
      parallel_tool_calls:
        Zoi.boolean(description: "Allow parallel tool calls")
        |> Zoi.optional()
    }
  end
end
