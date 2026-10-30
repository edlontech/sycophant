defmodule Sycophant.Error.Invalid.MissingModel do
  @moduledoc false
  use Splode.Error, fields: [:message], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{message: message}) when is_binary(message), do: message
  def message(_), do: "No model specified. Provide a model via the :model option."
end
