defmodule Sycophant.Pricing.Component do
  @moduledoc """
  A single pricing component from LLMDB's pricing model.

  Components have a `kind` that determines their billing unit:
  - `"token"` -- per-token rates (input, output, cache, reasoning)
  - `"tool"` -- per-call rates for built-in tools (web_search, file_search, etc.)
  - `"image"` -- per-image rates by size/quality
  - `"storage"` -- per-unit storage rates
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("PricingComponent") |> Zoi.default("PricingComponent"),
            id: Zoi.optional(Zoi.string()),
            kind: Zoi.optional(Zoi.string()),
            unit: Zoi.optional(Zoi.string()),
            per: Zoi.optional(Zoi.integer()),
            rate: Zoi.optional(Zoi.number()),
            tool: Zoi.optional(Zoi.string()),
            meter: Zoi.optional(Zoi.string()),
            size_class: Zoi.optional(Zoi.string()),
            notes: Zoi.optional(Zoi.string())

  @fields [:id, :kind, :unit, :per, :rate, :tool, :meter, :size_class, :notes]

  @doc "Converts an LLMDB component map (atom-keyed) into a Component struct."
  @spec from_llmdb(map()) :: t()
  def from_llmdb(map) when is_map(map) do
    struct(__MODULE__, Map.take(map, @fields))
  end
end

defmodule Sycophant.Pricing do
  @moduledoc """
  Represents pricing metadata from LLMDB's component-based pricing model.

  Attached to `Sycophant.Usage` as reference data after cost calculation.
  Contains the currency and all pricing components (tokens, tools, images, storage).
  """
  alias Sycophant.Pricing.Component

  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Pricing") |> Zoi.default("Pricing"),
            currency: Zoi.optional(Zoi.string()),
            components: Zoi.list(Sycophant.Pricing.Component.t()) |> Zoi.default([])

  @doc "Converts an LLMDB pricing map (atom-keyed) into a Pricing struct."
  @spec from_llmdb(map()) :: t()
  def from_llmdb(%{currency: currency, components: components}) do
    %__MODULE__{
      currency: currency,
      components: Enum.map(components, &Component.from_llmdb/1)
    }
  end

  @doc "Finds a component by ID."
  @spec find_component(t(), String.t()) :: Component.t() | nil
  def find_component(%__MODULE__{components: components}, id) do
    Enum.find(components, &(&1.id == id))
  end
end
