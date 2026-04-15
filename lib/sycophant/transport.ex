defmodule Sycophant.Transport do
  @moduledoc """
  HTTP transport layer built on Tesla.

  Constructs a fresh Tesla client per request and executes HTTP POSTs,
  mapping HTTP status codes to Splode error structs. Auth middleware is
  injected by the caller via `:auth_middlewares`, keeping Transport
  agnostic about authentication schemes.

  ## Error Mapping

    * `401` -> `AuthenticationFailed`
    * `404` -> `ModelNotFound`
    * `429` -> `RateLimited` (with `Retry-After` parsing)
    * `400-499` -> `BadRequest`
    * `500+` -> `ServerError`
  """

  alias Sycophant.Error

  @doc "Sends a synchronous HTTP POST and returns the decoded body."
  @spec call(map(), keyword()) :: {:ok, map()} | {:error, Splode.Error.t()}
  def call(payload, opts) do
    client = build_client(opts)
    path = Keyword.fetch!(opts, :path)

    case Tesla.post(client, path, payload, opts: request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

      {:error, reason} ->
        map_connection_error(reason)
    end
  end

  @doc "Sends a synchronous HTTP POST and returns the decoded body along with response headers."
  @spec call_raw(map(), keyword()) ::
          {:ok, {map(), [{String.t(), String.t()}]}} | {:error, Splode.Error.t()}
  def call_raw(payload, opts) do
    client = build_client(opts)
    path = Keyword.fetch!(opts, :path)

    case Tesla.post(client, path, payload, opts: request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, {body, headers}}

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

      {:error, reason} ->
        map_connection_error(reason)
    end
  end

  @doc "Sends a streaming HTTP POST using SSE and yields the event stream to `on_event`."
  @spec stream(map(), keyword(), (Enumerable.t() -> term())) ::
          {:ok, term()} | {:error, Splode.Error.t()}
  def stream(payload, opts, on_event) do
    client = build_stream_client(opts)
    path = Keyword.fetch!(opts, :path)
    body = JSON.encode!(payload)

    case Tesla.post(client, path, body, opts: request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: event_stream}} when status in 200..299 ->
        {:ok, on_event.(event_stream)}

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

      {:error, reason} ->
        map_connection_error(reason)
    end
  end

  @doc "Sends a streaming HTTP POST for binary event-stream protocols and yields raw chunks to `on_chunks`."
  @spec stream_binary(map(), keyword(), (Enumerable.t() -> term())) ::
          {:ok, term()} | {:error, Splode.Error.t()}
  def stream_binary(payload, opts, on_chunks) do
    client = build_binary_stream_client(opts)
    path = Keyword.fetch!(opts, :path)
    body = JSON.encode!(payload)

    case Tesla.post(client, path, body, opts: request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: binary_stream}} when status in 200..299 ->
        {:ok, on_chunks.(binary_stream)}

      {:ok, %Tesla.Env{} = env} ->
        map_error(env)

      {:error, reason} ->
        map_connection_error(reason)
    end
  end

  defp request_opts(opts) do
    case Keyword.get(opts, :path_params) do
      nil -> []
      params -> [path_params: params]
    end
  end

  defp build_client(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    {:ok, tesla_config} = Sycophant.Config.tesla()
    adapter = Keyword.get(opts, :adapter) || tesla_config.adapter

    middlewares =
      [
        {Tesla.Middleware.BaseUrl, base_url},
        Tesla.Middleware.PathParams,
        Tesla.Middleware.JSON
      ] ++
        Keyword.get(opts, :auth_middlewares, []) ++
        timeout_middleware(tesla_config) ++
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
        Tesla.Middleware.PathParams,
        {Tesla.Middleware.Headers, [{"content-type", "application/json"}]},
        Tesla.Middleware.SSE
      ] ++
        Keyword.get(opts, :auth_middlewares, []) ++
        timeout_middleware(tesla_config) ++
        Keyword.get(opts, :middlewares, tesla_config.middlewares)

    Tesla.client(middlewares, adapter)
  end

  defp build_binary_stream_client(opts) do
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
        Tesla.Middleware.PathParams,
        {Tesla.Middleware.Headers,
         [{"content-type", "application/json"}, {"accept", "application/vnd.amazon.eventstream"}]}
      ] ++
        Keyword.get(opts, :auth_middlewares, []) ++
        timeout_middleware(tesla_config) ++
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

  defp timeout_middleware(%{timeout: timeout}) when is_integer(timeout) do
    [{Tesla.Middleware.Timeout, timeout: timeout}]
  end

  defp timeout_middleware(_), do: []

  @timeout_reasons [:timeout, :connect_timeout, :checkout_timeout]

  defp map_connection_error(reason) when reason in @timeout_reasons do
    {:error, Error.Provider.Timeout.exception(reason: reason)}
  end

  defp map_connection_error({:timeout, detail}) do
    {:error, Error.Provider.Timeout.exception(reason: {:timeout, detail})}
  end

  defp map_connection_error(reason) do
    {:error, Error.Unknown.Unknown.exception(error: reason)}
  end
end
