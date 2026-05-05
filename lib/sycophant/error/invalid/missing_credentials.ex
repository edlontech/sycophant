defmodule Sycophant.Error.Invalid.MissingCredentials do
  @moduledoc false
  use Splode.Error, fields: [:provider, :errors], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{provider: provider, errors: errors})
      when not is_nil(provider) and is_list(errors) and errors != [] do
    "Could not resolve credentials for provider: #{provider} (#{Enum.join(errors, "; ")})"
  end

  def message(%{provider: provider}) when not is_nil(provider),
    do: "Could not resolve credentials for provider: #{provider}"

  def message(_), do: "Could not resolve credentials."
end
