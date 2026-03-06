defmodule Sycophant.Pipeline do
  @moduledoc """
  Orchestrates the full request lifecycle: model resolution, parameter
  validation, credential resolution, wire encoding, transport, and
  wire decoding.
  """

  alias Sycophant.Auth
  alias Sycophant.Context
  alias Sycophant.Credentials
  alias Sycophant.Error
  alias Sycophant.Message
  alias Sycophant.ModelResolver
  alias Sycophant.ResponseValidator
  alias Sycophant.Telemetry
  alias Sycophant.ToolExecutor
  alias Sycophant.Transport

  @param_keys [
    :temperature,
    :max_tokens,
    :top_p,
    :top_k,
    :stop,
    :seed,
    :frequency_penalty,
    :presence_penalty,
    :reasoning,
    :reasoning_summary,
    :parallel_tool_calls,
    :cache_key,
    :cache_retention,
    :safety_identifier,
    :service_tier,
    :tool_choice
  ]

  @spec call([Sycophant.Message.t()], keyword()) ::
          {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}
  def call(messages, opts) do
    with {:ok, model_info} <- ModelResolver.resolve(opts[:model]) do
      telemetry_metadata = %{
        model: "#{model_info.provider}:#{model_info.model_id}",
        provider: model_info.provider,
        wire_protocol: model_info.wire_adapter,
        has_tools?: opts[:tools] != nil and opts[:tools] != [],
        has_stream?: opts[:stream] != nil
      }

      Telemetry.span(telemetry_metadata, fn ->
        execute(messages, opts, model_info)
      end)
    end
  end

  defp execute(messages, opts, model_info) do
    adapter = model_info.wire_adapter

    with {:ok, params} <- validate_params(opts),
         {:ok, credentials} <- Credentials.resolve(model_info.provider, opts[:credentials]),
         {:ok, response} <-
           dispatch_call(messages, params, opts, model_info, adapter, credentials),
         {:ok, response} <-
           maybe_tool_loop(response, opts, params, model_info, adapter, credentials) do
      maybe_validate_response(response, opts)
    end
  end

  defp maybe_tool_loop(response, opts, params, model_info, adapter, credentials) do
    tools = opts[:tools] || []

    if has_executable_tools?(tools) and response.tool_calls != [] do
      call_fn = fn msgs ->
        dispatch_call(msgs, params, opts, model_info, adapter, credentials)
      end

      ToolExecutor.run(response, tools, opts, call_fn)
    else
      {:ok, response}
    end
  end

  defp dispatch_call(messages, params, opts, model_info, adapter, credentials) do
    case opts[:stream] do
      nil ->
        single_call(messages, params, opts, model_info, adapter, credentials)

      false ->
        single_call(messages, params, opts, model_info, adapter, credentials)

      callback when is_function(callback, 1) ->
        stream_call(messages, params, opts, model_info, adapter, credentials)

      other ->
        {:error,
         Error.Invalid.InvalidParams.exception(
           errors: [":stream must be a function/1, got: #{inspect(other)}"]
         )}
    end
  end

  defp stream_call(messages, params, opts, model_info, adapter, credentials) do
    callback = opts[:stream]

    with {:ok, request} <- build_request(messages, params, opts, model_info),
         {:ok, payload} <- adapter.encode_request(request) do
      transport_type =
        if function_exported?(adapter, :stream_transport, 0),
          do: adapter.stream_transport(),
          else: :sse

      result =
        case transport_type do
          :sse ->
            sse_stream(payload, request, model_info, credentials, adapter, callback)

          :event_stream ->
            binary_stream(payload, request, model_info, credentials, adapter, callback)
        end

      case result do
        {:ok, {:done, response}} ->
          {:ok, attach_context(response, messages, params, opts)}

        {:ok, {:error, _} = error} ->
          error

        {:ok, {:ok, _state}} ->
          {:error,
           Error.Provider.ResponseInvalid.exception(
             errors: ["Stream ended without a completed response"]
           )}

        {:error, _} = error ->
          error
      end
    end
  end

  defp sse_stream(payload, request, model_info, credentials, adapter, callback) do
    Transport.stream(
      payload,
      transport_opts(model_info, credentials, request),
      fn event_stream ->
        initial_state = adapter.init_stream()
        process_event_stream(event_stream, initial_state, adapter, callback)
      end
    )
  end

  defp binary_stream(payload, request, model_info, credentials, adapter, callback) do
    Transport.stream_binary(
      payload,
      transport_opts(model_info, credentials, request),
      fn binary_stream ->
        initial_state = adapter.init_stream()
        process_binary_stream(binary_stream, <<>>, initial_state, adapter, callback)
      end
    )
  end

  defp process_binary_stream(binary_stream, buffer, state, adapter, callback) do
    stream = if is_binary(binary_stream), do: [binary_stream], else: binary_stream

    Enum.reduce_while(stream, {:ok, buffer, state}, fn chunk, {:ok, buf, st} ->
      data = buf <> chunk

      case process_event_frames(data, st, adapter, callback) do
        {:ok, rest, new_state} ->
          {:cont, {:ok, rest, new_state}}

        {:done, response} ->
          {:halt, {:done, response}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _buf, final_state} -> {:ok, final_state}
      {:done, _} = done -> done
      {:error, _} = error -> error
    end
  end

  defp process_event_frames(data, state, adapter, callback) do
    case Sycophant.AWS.EventStream.decode_frame(data) do
      {:ok, raw_event, rest} ->
        event = decode_event_stream_frame(raw_event)

        case adapter.decode_stream_chunk(state, event) do
          {:ok, new_state, chunks} ->
            fire_stream_events(chunks, callback)
            process_event_frames(rest, new_state, adapter, callback)

          {:done, response} ->
            {:done, response}

          {:done, response, chunks} ->
            fire_stream_events(chunks, callback)
            {:done, response}

          {:error, _} = error ->
            error
        end

      {:incomplete, rest} ->
        {:ok, rest, state}

      {:error, _} = error ->
        error
    end
  end

  defp decode_event_stream_frame(%{headers: headers, payload: payload}) do
    event_type = Map.get(headers, ":event-type", "unknown")

    parsed_payload =
      case payload do
        "" ->
          %{}

        bin ->
          case JSON.decode(bin) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{}
          end
      end

    %{event_type: event_type, payload: parsed_payload}
  end

  defp process_event_stream(event_stream, initial_state, adapter, callback) do
    Enum.reduce_while(event_stream, {:ok, initial_state}, fn event, {:ok, state} ->
      case decode_sse_data(event) do
        {:ok, decoded_event} ->
          case adapter.decode_stream_chunk(state, decoded_event) do
            {:ok, new_state, chunks} ->
              fire_stream_events(chunks, callback)
              {:cont, {:ok, new_state}}

            {:done, response} ->
              {:halt, {:done, response}}

            {:done, response, chunks} ->
              fire_stream_events(chunks, callback)
              {:halt, {:done, response}}

            {:error, _} = error ->
              {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp decode_sse_data(%{data: "[DONE]"} = event), do: {:ok, event}

  defp decode_sse_data(%{data: data} = event) when is_binary(data) do
    case JSON.decode(data) do
      {:ok, decoded} ->
        {:ok, %{event | data: decoded}}

      {:error, _} ->
        {:error,
         Error.Provider.ResponseInvalid.exception(errors: ["Invalid JSON in SSE data: #{data}"])}
    end
  end

  defp decode_sse_data(event), do: {:ok, event}

  defp fire_stream_events(chunks, callback) do
    Enum.each(chunks, fn chunk ->
      Telemetry.stream_chunk(chunk)
      callback.(chunk)
    end)
  end

  defp single_call(messages, params, opts, model_info, adapter, credentials) do
    with {:ok, request} <- build_request(messages, params, opts, model_info),
         {:ok, payload} <- adapter.encode_request(request),
         {:ok, body} <- Transport.call(payload, transport_opts(model_info, credentials, request)),
         {:ok, response} <- adapter.decode_response(body) do
      {:ok, attach_context(response, messages, params, opts)}
    end
  end

  defp has_executable_tools?(tools) do
    Enum.any?(tools, & &1.function)
  end

  defp maybe_validate_response(response, opts) do
    case opts[:response_schema] do
      nil ->
        {:ok, response}

      schema ->
        validate? = Keyword.get(opts, :validate, true)
        ResponseValidator.validate(response, schema, validate?)
    end
  end

  defp attach_context(response, messages, params, opts) do
    assistant_msg = %Message{
      role: :assistant,
      content: response.text,
      tool_calls: if(response.tool_calls in [nil, []], do: nil, else: response.tool_calls)
    }

    context = %Context{
      messages: messages ++ [assistant_msg],
      model: opts[:model],
      params: params,
      provider_params: opts[:provider_params] || %{},
      tools: opts[:tools] || [],
      stream: opts[:stream],
      response_schema: opts[:response_schema]
    }

    %{response | context: context}
  end

  defp validate_params(opts) do
    param_data = opts |> Keyword.take(@param_keys) |> Map.new()

    case Zoi.parse(Sycophant.Params.t(), param_data) do
      {:ok, params} ->
        {:ok, params}

      {:error, errors} ->
        {:error,
         Error.Invalid.InvalidParams.exception(errors: Enum.map(errors, &to_string(&1.message)))}
    end
  end

  defp build_request(messages, params, opts, model_info) do
    {:ok,
     %Sycophant.Request{
       messages: messages,
       model: model_info.model_id,
       resolved_model: model_info.model_struct,
       wire_protocol: model_info.wire_adapter,
       params: params,
       provider_params: opts[:provider_params] || %{},
       tools: opts[:tools] || [],
       stream: opts[:stream],
       response_schema: opts[:response_schema]
     }}
  end

  defp transport_opts(model_info, credentials, request) do
    [
      base_url: model_info.base_url,
      path: model_info.wire_adapter.request_path(request),
      auth_middlewares: Auth.middlewares_for(model_info.provider, credentials),
      path_params: Auth.path_params_for(model_info.provider, credentials)
    ]
  end
end
