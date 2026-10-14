defmodule Sycophant.OAuth.HTTPAdapter do
  @moduledoc "Assent HTTP adapter using Sycophant's Tesla configuration without body decoding."
  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPResponse

  @doc "Sends a raw OAuth request; HTTP error statuses are returned to Assent unchanged."
  @impl true
  @spec request(atom(), binary(), binary() | nil, [{binary(), binary()}], keyword()) ::
          {:ok, HTTPResponse.t()} | {:error, term()}
  def request(method, url, body, headers, opts) do
    {:ok, tesla_config} = Sycophant.Config.tesla()
    client = Tesla.client([{Tesla.Middleware.Headers, headers}], tesla_config.adapter)

    result =
      case method do
        :post -> Tesla.post(client, url, body, opts || [])
        :get -> Tesla.get(client, url, opts || [])
      end

    case result do
      {:ok, %Tesla.Env{status: status, headers: headers, body: body}} ->
        {:ok,
         %HTTPResponse{
           status: status,
           headers: headers,
           body: body,
           http_adapter: __MODULE__,
           request_url: url
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
