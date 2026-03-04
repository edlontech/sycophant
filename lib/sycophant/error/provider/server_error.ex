defmodule Sycophant.Error.Provider.ServerError do
  @moduledoc false
  use Splode.Error, fields: [:status, :body], class: :provider

  def message(%{status: status, body: body}) when is_integer(status) do
    "Provider returned server error (HTTP #{status}): #{body}"
  end

  def message(%{status: status}) when is_integer(status) do
    "Provider returned server error (HTTP #{status})."
  end

  def message(_), do: "Provider returned server error."
end
