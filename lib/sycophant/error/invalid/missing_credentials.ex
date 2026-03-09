defmodule Sycophant.Error.Invalid.MissingCredentials do
  @moduledoc false
  use Splode.Error, fields: [:provider], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{provider: provider}) when not is_nil(provider),
    do: "Could not resolve credentials for provider: #{provider}"

  def message(_), do: "Could not resolve credentials."
end
