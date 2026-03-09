defmodule Sycophant.Error.Invalid.InvalidSerialization do
  @moduledoc false
  use Splode.Error, fields: [:reason], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{reason: reason}), do: reason
end
