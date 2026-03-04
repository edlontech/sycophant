defmodule Sycophant.Transport do
  @moduledoc """
  Builds a fresh Tesla client per request and executes HTTP POST,
  mapping HTTP status codes to Splode error structs.

  Auth middleware is injected by the caller via the `:auth_middlewares`
  option, keeping Transport agnostic about authentication schemes
  (Bearer tokens, API-key headers, AWS SigV4, etc.).
  """

  alias Sycophant.Error

  @spec call(map(), keyword()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def call(payload, opts) do
    client = build_client(opts)
    path = Keyword.fetch!(opts, :path)

    case Tesla.post(client, path, payload) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Tesla.Env{status: 401, body: body}} ->
        {:error, Error.Provider.AuthenticationFailed.exception(status: 401, body: inspect(body))}

      {:ok, %Tesla.Env{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        {:error, Error.Provider.RateLimited.exception(retry_after: retry_after)}

      {:ok, %Tesla.Env{status: 404, body: body}} ->
        {:error, Error.Provider.ModelNotFound.exception(model: inspect(body))}

      {:ok, %Tesla.Env{status: status, body: body}} when status in 400..499 ->
        {:error, Error.Provider.BadRequest.exception(status: status, body: inspect(body))}

      {:ok, %Tesla.Env{status: status, body: body}} when status >= 500 ->
        {:error, Error.Provider.ServerError.exception(status: status, body: inspect(body))}

      {:error, reason} ->
        {:error, Error.Unknown.Unknown.exception(error: reason)}
    end
  end

  defp build_client(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    {:ok, tesla_config} = Sycophant.Config.tesla()
    adapter = Keyword.get(opts, :adapter) || tesla_config.adapter

    middlewares =
      [
        {Tesla.Middleware.BaseUrl, base_url},
        Tesla.Middleware.JSON
      ] ++
        Keyword.get(opts, :auth_middlewares, []) ++
        Keyword.get(opts, :middlewares, tesla_config.middlewares)

    Tesla.client(middlewares, adapter)
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> parse_retry_after(value)
      nil -> nil
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _} -> seconds
      :error -> nil
    end
  end

  defp parse_retry_after(value), do: value
end
