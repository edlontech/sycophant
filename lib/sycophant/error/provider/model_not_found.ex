defmodule Sycophant.Error.Provider.ModelNotFound do
  @moduledoc false
  use Splode.Error, fields: [:model], class: :provider

  def message(%{model: model}) when not is_nil(model) do
    "Model #{model} not found or unavailable at provider."
  end

  def message(_), do: "Model not found or unavailable at provider."
end
