defmodule Sycophant.Error.Invalid.InvalidResponse do
  @moduledoc false
  use Splode.Error, fields: [:errors], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{errors: errors}) do
    "Response validation failed: #{Enum.join(List.wrap(errors), ", ")}"
  end
end
