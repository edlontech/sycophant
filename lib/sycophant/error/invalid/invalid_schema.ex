defmodule Sycophant.Error.Invalid.InvalidSchema do
  @moduledoc false
  use Splode.Error, fields: [:errors, :target, :context], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{errors: errors, target: target, context: context})
      when is_list(errors) and not is_nil(target) and not is_nil(context) do
    details = Enum.map_join(errors, ", ", &to_string/1)
    "Invalid Zoi schema for #{target} (#{context}): #{details}"
  end

  def message(%{errors: errors, target: target}) when is_list(errors) and not is_nil(target) do
    details = Enum.map_join(errors, ", ", &to_string/1)
    "Invalid Zoi schema for #{target}: #{details}"
  end

  def message(%{errors: errors}) when is_list(errors) do
    details = Enum.map_join(errors, ", ", &to_string/1)
    "Invalid Zoi schema: #{details}"
  end

  def message(%{errors: errors}) when not is_nil(errors) do
    "Invalid Zoi schema: #{inspect(errors)}"
  end

  def message(_), do: "Invalid Zoi schema provided."
end
