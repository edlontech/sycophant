defmodule Sycophant.Error.Provider.SubscriptionError do
  @moduledoc "A rejection of a ChatGPT plan request by the provider."
  use Splode.Error, fields: [:code, :status, :param, :request_id, :detail], class: :provider

  @type t :: %__MODULE__{
          code: String.t(),
          status: integer() | nil,
          param: String.t() | nil,
          request_id: String.t() | nil,
          detail: String.t() | nil
        }

  def message(%{code: code, detail: nil}), do: "ChatGPT plan request rejected (#{code})"

  def message(%{code: code, detail: detail}) do
    "ChatGPT plan request rejected (#{code}): #{detail}"
  end

  @doc "Extracts subscription failures from a provider error body and response headers."
  @spec from_body(map() | binary(), [{String.t(), String.t()}]) :: t() | nil
  def from_body(body, headers \\ [])

  def from_body(body, headers) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> from_body(decoded, headers)
      {:error, _} -> nil
    end
  end

  def from_body(%{"error" => %{"code" => code} = error}, headers) when is_binary(code) do
    if String.starts_with?(code, ["subscription_sharing_", "chatpass_v2_"]) do
      exception(
        code: code,
        param: error["param"],
        request_id: request_id(headers),
        detail: error["message"]
      )
    end
  end

  def from_body(_, _), do: nil

  defp request_id(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "x-request-id", do: value
    end)
  end
end
