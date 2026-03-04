defmodule Sycophant.Error.Provider.ContentFiltered do
  @moduledoc false
  use Splode.Error, fields: [:reason], class: :provider

  def message(%{reason: reason}) when not is_nil(reason) do
    "Content filtered by provider safety system: #{reason}"
  end

  def message(_), do: "Content filtered by provider safety system."
end
