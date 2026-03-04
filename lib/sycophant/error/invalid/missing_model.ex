defmodule Sycophant.Error.Invalid.MissingModel do
  @moduledoc false
  use Splode.Error, fields: [], class: :invalid

  def message(_), do: "No model specified. Provide a model via the :model option."
end
