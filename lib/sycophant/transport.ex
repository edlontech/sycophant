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

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

      {:error, reason} ->
        {:error, Error.Unknown.Unknown.exception(error: reason)}
    end
  end

  @spec stream(map(), keyword(), (Enumerable.t() -> term())) ::
          {:ok, term()} | {:error, Splode.Error.t()}
  def stream(payload, opts, on_event) do
    client = build_stream_client(opts)
    path = Keyword.fetch!(opts, :path)
    body = JSON.encode!(payload)

    case Tesla.post(client, path, body) do
      {:ok, %Tesla.Env{status: status, body: event_stream}} when status in 200..299 ->
        {:ok, on_event.(event_stream)}

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

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

  defp build_stream_client(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    {:ok, tesla_config} = Sycophant.Config.tesla()
    raw_adapter = Keyword.get(opts, :adapter) || tesla_config.adapter

    adapter =
      case raw_adapter do
        mod when is_atom(mod) ->
          {mod, [response: :stream]}

        {mod, adapter_opts} when is_atom(mod) ->
          {mod, Keyword.put(adapter_opts, :response, :stream)}

        other ->
          other
      end

    middlewares =
      [
        {Tesla.Middleware.BaseUrl, base_url},
        {Tesla.Middleware.Headers, [{"content-type", "application/json"}]},
        Tesla.Middleware.SSE
      ] ++
        Keyword.get(opts, :auth_middlewares, []) ++
        Keyword.get(opts, :middlewares, tesla_config.middlewares)

    Tesla.client(middlewares, adapter)
  end

  defp map_error(%Tesla.Env{status: 401, body: body}) do
    {:error, Error.Provider.AuthenticationFailed.exception(status: 401, body: inspect(body))}
  end

  defp map_error(%Tesla.Env{status: 429, headers: headers}) do
    {:error, Error.Provider.RateLimited.exception(retry_after: get_retry_after(headers))}
  end

  defp map_error(%Tesla.Env{status: 404, body: body}) do
    {:error, Error.Provider.ModelNotFound.exception(model: inspect(body))}
  end

  defp map_error(%Tesla.Env{status: status, body: body}) when status in 400..499 do
    {:error, Error.Provider.BadRequest.exception(status: status, body: inspect(body))}
  end

  defp map_error(%Tesla.Env{status: status, body: body}) when status >= 500 do
    {:error, Error.Provider.ServerError.exception(status: status, body: inspect(body))}
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
