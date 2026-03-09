defmodule Sycophant.Error.Invalid.MissingModel do
  @moduledoc false
  use Splode.Error, fields: [], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(_), do: "No model specified. Provide a model via the :model option."
end
