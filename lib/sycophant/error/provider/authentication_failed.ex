defmodule Sycophant.Error.Provider.AuthenticationFailed do
  @moduledoc false
  use Splode.Error, fields: [:status, :body], class: :provider

  def message(%{status: status, body: body}) when is_integer(status) do
    "Authentication failed (HTTP #{status}): #{body}"
  end

  def message(%{status: status}) when is_integer(status) do
    "Authentication failed (HTTP #{status})."
  end

  def message(_), do: "Authentication failed."
end
