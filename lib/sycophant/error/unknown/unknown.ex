defmodule Sycophant.Error.Unknown.Unknown do
  @moduledoc false
  use Splode.Error, fields: [:error], class: :unknown

  def message(%{error: error}) when is_binary(error), do: error
  def message(%{error: error}), do: "Unknown error: #{inspect(error)}"
  def message(_), do: "An unknown error occurred."
end
