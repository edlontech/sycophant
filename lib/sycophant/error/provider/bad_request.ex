defmodule Sycophant.Error.Provider.BadRequest do
  @moduledoc false
  use Splode.Error, fields: [:status, :body], class: :provider

  def message(%{status: status, body: body}) when is_integer(status) do
    "Provider rejected the request (HTTP #{status}): #{body}"
  end

  def message(%{status: status}) when is_integer(status) do
    "Provider rejected the request (HTTP #{status})."
  end

  def message(_), do: "Provider rejected the request."
end
