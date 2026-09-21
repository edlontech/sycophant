defmodule Sycophant.EvaluationPipeline do
  @moduledoc """
  Orchestrates the evaluation request lifecycle.

  Follows the same pattern as `Sycophant.EmbeddingPipeline` but for
  evaluation models: resolves the model, resolves credentials, encodes via
  the evaluation wire protocol adapter, transports, decodes the response,
  and re-keys the answers from the adapter's string ids back to the
  caller's original question keys. Evaluation requests have no params to
  validate.
  """

  alias Sycophant.Auth
  alias Sycophant.Credentials
  alias Sycophant.EvaluationRequest
  alias Sycophant.ModelResolver
  alias Sycophant.Transport

  @doc "Executes a full evaluation request pipeline: resolves model, encodes, transports, decodes, and re-keys answers."
  @spec call(EvaluationRequest.t(), keyword()) ::
          {:ok, Sycophant.EvaluationResponse.t()} | {:error, Splode.Error.t()}
  def call(%EvaluationRequest{} = request, opts \\ []) do
    with {:ok, model_info} <- ModelResolver.resolve_evaluation(request.model),
         {:ok, credentials} <- Credentials.resolve(model_info.provider, opts[:credentials]) do
      telemetry_metadata = %{
        model: "#{model_info.provider}:#{model_info.model_id}",
        provider: model_info.provider,
        question_count: map_size(request.questions)
      }

      evaluation_span(telemetry_metadata, fn ->
        request = %{request | model: model_info.model_id}
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
      {:ok,
       %{
         response
         | answers: rekey_answers(request, response.answers),
           model: response.model || model_info.model_id
       }}
    end
  end

  defp rekey_answers(request, answers) do
    lookup = Map.new(request.questions, fn {k, _} -> {to_string(k), k} end)
    Map.new(answers, fn {id, answer} -> {Map.get(lookup, id, id), answer} end)
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

  @evaluation_start [:sycophant, :evaluation, :start]
  @evaluation_stop [:sycophant, :evaluation, :stop]
  @evaluation_error [:sycophant, :evaluation, :error]

  defp evaluation_span(metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute(@evaluation_start, %{system_time: System.system_time()}, metadata)

    case fun.() do
      {:ok, response} = result ->
        duration = System.monotonic_time() - start_time

        stop_metadata =
          Map.merge(metadata, %{
            duration: duration,
            usage: format_usage(response.usage)
          })

        :telemetry.execute(@evaluation_stop, %{duration: duration}, stop_metadata)
        result

      {:error, error} = result ->
        duration = System.monotonic_time() - start_time

        error_metadata =
          Map.merge(metadata, %{
            error: error,
            error_class: error_class(error)
          })

        :telemetry.execute(@evaluation_error, %{duration: duration}, error_metadata)
        result
    end
  end

  defp format_usage(nil), do: nil

  defp format_usage(%Sycophant.Usage{} = usage) do
    %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}
  end

  defp error_class(%{class: class}), do: class
  defp error_class(_), do: :unknown
end
