defmodule Sycophant.OAuth.HTTPAdapter do
  @moduledoc "Assent HTTP adapter using Sycophant's Tesla configuration without body decoding."
  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPRequest
  alias Assent.HTTPAdapter.HTTPResponse

  @doc "Sends a raw OAuth request; HTTP error statuses are returned to Assent unchanged."
  @impl true
  @spec request(atom(), binary(), binary() | nil, [{binary(), binary()}], keyword()) ::
          {:ok, HTTPResponse.t()} | {:error, term()}
  def request(method, url, body, headers, _opts) do
    {:ok, tesla_config} = Sycophant.Config.tesla()
    client = Tesla.client([{Tesla.Middleware.Headers, headers}], tesla_config.adapter)

    result =
      case method do
        :post -> Tesla.post(client, url, body, [])
        :get -> Tesla.get(client, url, [])
      end

    with {:ok, %Tesla.Env{status: status, headers: resp_headers, body: resp_body}} <- result do
      {:ok,
       %HTTPResponse{
         status: status,
         headers: resp_headers,
         body: resp_body,
         http_adapter: __MODULE__,
         request: %HTTPRequest{method: method, url: url, headers: headers, body: body}
       }}
    end
  end
end
