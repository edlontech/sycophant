defmodule Sycophant.Pricing do
  @moduledoc """
  Represents pricing metadata from LLMDB's component-based pricing model.

  Attached to `Sycophant.Usage` as reference data after cost calculation.
  Contains the currency and all pricing components (tokens, tools, images, storage).
  """
  use TypedStruct

  alias Sycophant.Pricing.Component

  typedstruct do
    field :currency, String.t()
    field :components, [Component.t()], default: []
  end

  @doc "Converts an LLMDB pricing map (atom-keyed) into a Pricing struct."
  @spec from_llmdb(map()) :: t()
  def from_llmdb(%{currency: currency, components: components}) do
    %__MODULE__{
      currency: currency,
      components: Enum.map(components, &Component.from_llmdb/1)
    }
  end

  @doc "Reconstructs a Pricing struct from a serialized map (string-keyed)."
  @spec from_map(map()) :: t()
  def from_map(%{"currency" => currency, "components" => components}) do
    %__MODULE__{
      currency: currency,
      components: Enum.map(components, &Component.from_map/1)
    }
  end

  def from_map(%{"currency" => currency}) do
    %__MODULE__{currency: currency, components: []}
  end

  @doc "Finds a component by ID."
  @spec find_component(t(), String.t()) :: Component.t() | nil
  def find_component(%__MODULE__{components: components}, id) do
    Enum.find(components, &(&1.id == id))
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Pricing do
  import Sycophant.Serializable.Helpers

  def to_map(pricing) do
    compact(%{
      "__type__" => "Pricing",
      "currency" => pricing.currency,
      "components" => Enum.map(pricing.components, &Sycophant.Serializable.to_map/1)
    })
  end
end

defmodule Sycophant.Pricing.Component do
  @moduledoc """
  A single pricing component from LLMDB's pricing model.

  Components have a `kind` that determines their billing unit:
  - `"token"` -- per-token rates (input, output, cache, reasoning)
  - `"tool"` -- per-call rates for built-in tools (web_search, file_search, etc.)
  - `"image"` -- per-image rates by size/quality
  - `"storage"` -- per-unit storage rates
  """
  use TypedStruct

  typedstruct do
    field :id, String.t()
    field :kind, String.t()
    field :unit, String.t()
    field :per, pos_integer()
    field :rate, number()
    field :tool, String.t()
    field :meter, String.t()
    field :size_class, String.t()
    field :notes, String.t()
  end

  @fields [:id, :kind, :unit, :per, :rate, :tool, :meter, :size_class, :notes]

  @doc "Converts an LLMDB component map (atom-keyed) into a Component struct."
  @spec from_llmdb(map()) :: t()
  def from_llmdb(map) when is_map(map) do
    struct(__MODULE__, Map.take(map, @fields))
  end

  @doc "Reconstructs a Component struct from a serialized map (string-keyed)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      kind: map["kind"],
      unit: map["unit"],
      per: map["per"],
      rate: map["rate"],
      tool: map["tool"],
      meter: map["meter"],
      size_class: map["size_class"],
      notes: map["notes"]
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Pricing.Component do
  import Sycophant.Serializable.Helpers

  def to_map(comp) do
    compact(%{
      "__type__" => "PricingComponent",
      "id" => comp.id,
      "kind" => comp.kind,
      "unit" => comp.unit,
      "per" => comp.per,
      "rate" => comp.rate,
      "tool" => comp.tool,
      "meter" => comp.meter,
      "size_class" => comp.size_class,
      "notes" => comp.notes
    })
  end
end
