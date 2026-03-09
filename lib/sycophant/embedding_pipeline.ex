defmodule Sycophant.EmbeddingPipeline do
  @moduledoc """
  Orchestrates the embedding request lifecycle: model resolution,
  parameter validation, credential resolution, wire encoding,
  transport, and wire decoding.
  """

  alias Sycophant.Auth
  alias Sycophant.Credentials
  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.Error
  alias Sycophant.ModelResolver
  alias Sycophant.Transport

  @embedding_param_keys [:dimensions, :embedding_types, :truncate, :max_tokens]

  @doc "Executes a full embedding request pipeline: resolves model, validates params, encodes, transports, and decodes."
  @spec call(EmbeddingRequest.t(), keyword()) ::
          {:ok, Sycophant.EmbeddingResponse.t()} | {:error, Splode.Error.t()}
  def call(%EmbeddingRequest{} = request, opts \\ []) do
    with {:ok, model_info} <- ModelResolver.resolve_embedding(request.model),
         {:ok, params} <- validate_params(request, opts),
         {:ok, credentials} <- Credentials.resolve(model_info.provider, opts[:credentials]) do
      telemetry_metadata = %{
        model: "#{model_info.provider}:#{model_info.model_id}",
        provider: model_info.provider,
        input_count: length(request.inputs),
        embedding_types: params.embedding_types,
        dimensions: params.dimensions
      }

      embedding_span(telemetry_metadata, fn ->
        model_id = resolve_model_id(model_info, opts)
        request = %{request | model: model_id, params: params}
        execute(request, model_info, credentials)
      end)
    end
  end

  defp execute(request, model_info, credentials) do
    adapter = model_info.wire_adapter

    with {:ok, payload} <- adapter.encode_request(request),
         {:ok, {body, headers}} <-
           Transport.call_raw(payload, transport_opts(model_info, credentials, request, adapter)),
         {:ok, response} <- adapter.decode_response(body, headers) do
      {:ok, %{response | model: model_info.model_id}}
    end
  end

  defp validate_params(%EmbeddingRequest{params: params}, _opts) when not is_nil(params) do
    param_data = params |> Map.from_struct() |> Map.reject(fn {_, v} -> is_nil(v) end)

    case Zoi.parse(EmbeddingParams.t(), param_data) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error,
         Error.Invalid.InvalidParams.exception(errors: Enum.map(errors, &to_string(&1.message)))}
    end
  end

  defp validate_params(_request, opts) do
    param_data = opts |> Keyword.take(@embedding_param_keys) |> Map.new()

    case Zoi.parse(EmbeddingParams.t(), param_data) do
      {:ok, params} ->
        {:ok, params}

      {:error, errors} ->
        {:error,
         Error.Invalid.InvalidParams.exception(errors: Enum.map(errors, &to_string(&1.message)))}
    end
  end

  defp resolve_model_id(model_info, opts) do
    case get_in(opts, [:credentials, :deployment_name]) do
      nil -> model_info.model_id
      name -> name
    end
  end

  defp transport_opts(model_info, credentials, request, adapter) do
    base_url = Map.get(credentials, :base_url, model_info.base_url)
    path_params = Auth.path_params_for(model_info.provider, credentials)
    {path_prefix, path_params} = Keyword.pop(path_params, :path_prefix, "")
    path = path_prefix <> adapter.request_path(request)

    [
      base_url: base_url,
      path: path,
      auth_middlewares: Auth.middlewares_for(model_info.provider, credentials),
      path_params: path_params
    ]
  end

  @embedding_start [:sycophant, :embedding, :start]
  @embedding_stop [:sycophant, :embedding, :stop]
  @embedding_error [:sycophant, :embedding, :error]

  defp embedding_span(metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute(@embedding_start, %{system_time: System.system_time()}, metadata)

    case fun.() do
      {:ok, response} = result ->
        duration = System.monotonic_time() - start_time

        stop_metadata =
          Map.merge(metadata, %{
            duration: duration,
            usage: format_usage(response.usage)
          })

        :telemetry.execute(@embedding_stop, %{duration: duration}, stop_metadata)
        result

      {:error, error} = result ->
        duration = System.monotonic_time() - start_time

        error_metadata =
          Map.merge(metadata, %{
            error: error,
            error_class: error_class(error)
          })

        :telemetry.execute(@embedding_error, %{duration: duration}, error_metadata)
        result
    end
  end

  defp format_usage(nil), do: nil

  defp format_usage(%Sycophant.Usage{} = usage) do
    %{input_tokens: usage.input_tokens}
  end

  defp error_class(%{class: class}), do: class
  defp error_class(_), do: :unknown
end
