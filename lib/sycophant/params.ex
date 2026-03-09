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
            seed: Zoi.optional(Zoi.integer()),
            frequency_penalty: Zoi.float() |> Zoi.min(-2.0) |> Zoi.max(2.0) |> Zoi.optional(),
            presence_penalty: Zoi.float() |> Zoi.min(-2.0) |> Zoi.max(2.0) |> Zoi.optional(),
            reasoning: Zoi.enum([:low, :medium, :high]) |> Zoi.optional(),
            reasoning_summary: Zoi.enum([:auto, :concise, :detailed, :none]) |> Zoi.optional(),
            parallel_tool_calls: Zoi.optional(Zoi.boolean()),
            cache_key: Zoi.optional(Zoi.string()),
            cache_retention: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
            safety_identifier: Zoi.optional(Zoi.string()),
            service_tier: Zoi.optional(Zoi.string()),
            tool_choice: Zoi.optional(Zoi.any())

  @doc "Deserializes params from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      temperature: data["temperature"],
      max_tokens: data["max_tokens"],
      top_p: data["top_p"],
      top_k: data["top_k"],
      stop: data["stop"],
      seed: data["seed"],
      frequency_penalty: data["frequency_penalty"],
      presence_penalty: data["presence_penalty"],
      reasoning: safe_atom(data["reasoning"], ~w(low medium high)),
      reasoning_summary: safe_atom(data["reasoning_summary"], ~w(auto concise detailed none)),
      parallel_tool_calls: data["parallel_tool_calls"],
      cache_key: data["cache_key"],
      cache_retention: data["cache_retention"],
      safety_identifier: data["safety_identifier"],
      service_tier: data["service_tier"],
      tool_choice: data["tool_choice"]
    }
  end

  defp safe_atom(nil, _allowed), do: nil

  defp safe_atom(value, allowed) do
    if value in allowed do
      String.to_existing_atom(value)
    else
      raise Sycophant.Error.Invalid.InvalidSerialization,
        reason: "invalid enum value: #{inspect(value)}, expected one of: #{inspect(allowed)}"
    end
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Params do
  import Sycophant.Serializable.Helpers

  def to_map(params) do
    compact(%{
      "__type__" => "Params",
      "temperature" => params.temperature,
      "max_tokens" => params.max_tokens,
      "top_p" => params.top_p,
      "top_k" => params.top_k,
      "stop" => params.stop,
      "seed" => params.seed,
      "frequency_penalty" => params.frequency_penalty,
      "presence_penalty" => params.presence_penalty,
      "reasoning" => atom_to_string(params.reasoning),
      "reasoning_summary" => atom_to_string(params.reasoning_summary),
      "parallel_tool_calls" => params.parallel_tool_calls,
      "cache_key" => params.cache_key,
      "cache_retention" => params.cache_retention,
      "safety_identifier" => params.safety_identifier,
      "service_tier" => params.service_tier,
      "tool_choice" => params.tool_choice
    })
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom), do: Atom.to_string(atom)
end
