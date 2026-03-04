defmodule Sycophant.Error.Provider.RateLimited do
  @moduledoc false
  use Splode.Error, fields: [:retry_after], class: :provider

  def message(%{retry_after: seconds}) when is_number(seconds) do
    "Rate limited by provider. Retry after #{seconds} seconds."
  end

  def message(_), do: "Rate limited by provider."
end
