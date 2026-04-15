defmodule Sycophant.Error.Provider.Timeout do
  @moduledoc false
  use Splode.Error, fields: [:reason], class: :provider

  def message(%{reason: reason}) when not is_nil(reason) do
    "Request timed out: #{inspect(reason)}"
  end

  def message(_), do: "Request timed out."
end
