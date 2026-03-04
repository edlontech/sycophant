defmodule Sycophant.Error.Provider.ResponseInvalid do
  @moduledoc false
  use Splode.Error, fields: [:errors, :raw], class: :provider

  def message(%{errors: errors}) when is_list(errors) do
    details = Enum.map_join(errors, ", ", &to_string/1)
    "Provider response did not match the expected schema: #{details}"
  end

  def message(%{errors: errors}) when not is_nil(errors) do
    "Provider response did not match the expected schema: #{inspect(errors)}"
  end

  def message(_), do: "Provider response did not match the expected schema."
end
