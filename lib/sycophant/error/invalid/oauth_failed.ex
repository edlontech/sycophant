defmodule Sycophant.Error.Invalid.OAuthFailed do
  @moduledoc "An OAuth authorization or token exchange failure."
  use Splode.Error, fields: [:reason, :code], class: :invalid

  @spec message(%__MODULE__{}) :: String.t()
  def message(%{reason: reason, code: code}) do
    detail = if is_exception(reason), do: Exception.message(reason), else: reason
    if is_nil(code), do: "OAuth failed: #{detail}", else: "OAuth failed (#{code}): #{detail}"
  end
end
