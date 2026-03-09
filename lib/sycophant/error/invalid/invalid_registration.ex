defmodule Sycophant.Error.Invalid.InvalidRegistration do
  @moduledoc false
  use Splode.Error, fields: [:module, :behaviour], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{module: module, behaviour: behaviour}) do
    "#{inspect(module)} does not implement the #{inspect(behaviour)} behaviour"
  end
end
