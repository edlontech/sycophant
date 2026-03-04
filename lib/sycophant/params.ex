defmodule Sycophant.Params do
  @moduledoc """
  Canonical LLM parameters with validation.

  All fields are optional — `nil` means the provider's default is used.
  Wire protocol adapters translate these into provider-specific parameter
  names and value formats, dropping any fields the provider doesn't support.

  Use `Params.t()` to get the Zoi schema for validation.
  """
  use ZoiDefstruct

  defstruct temperature: Zoi.float() |> Zoi.min(0.0) |> Zoi.max(2.0) |> Zoi.optional(),
            max_tokens: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            top_p: Zoi.float() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.optional(),
            top_k: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            stop: Zoi.list(Zoi.string()) |> Zoi.optional(),
            seed: Zoi.integer() |> Zoi.optional(),
            frequency_penalty: Zoi.float() |> Zoi.min(-2.0) |> Zoi.max(2.0) |> Zoi.optional(),
            presence_penalty: Zoi.float() |> Zoi.min(-2.0) |> Zoi.max(2.0) |> Zoi.optional(),
            reasoning: Zoi.enum([:low, :medium, :high]) |> Zoi.optional(),
            reasoning_summary: Zoi.enum([:auto, :concise, :detailed, :none]) |> Zoi.optional(),
            parallel_tool_calls: Zoi.boolean() |> Zoi.optional(),
            cache_key: Zoi.string() |> Zoi.optional(),
            cache_retention: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            safety_identifier: Zoi.string() |> Zoi.optional(),
            service_tier: Zoi.string() |> Zoi.optional()
end
