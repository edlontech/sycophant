defmodule Sycophant.Error.Invalid.InvalidEmbeddingInput do
  @moduledoc false
  use Splode.Error, fields: [:errors], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{errors: errors}) when is_list(errors) do
    details = Enum.map_join(errors, ", ", &to_string/1)
    "Invalid embedding input: #{details}"
  end

  def message(%{errors: errors}) when not is_nil(errors),
    do: "Invalid embedding input: #{inspect(errors)}"

  def message(_), do: "Invalid embedding input."
end
