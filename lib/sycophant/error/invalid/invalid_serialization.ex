defmodule Sycophant.Error.Invalid.InvalidSerialization do
  @moduledoc false
  use Splode.Error, fields: [:reason], class: :invalid

  def message(%{reason: reason}), do: reason
end
