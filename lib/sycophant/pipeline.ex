defmodule Sycophant.Pipeline do
  @moduledoc """
  Orchestrates the full LLM request lifecycle.

  The pipeline executes these steps in order:

  1. **Model Resolution** - Resolves the model spec to provider metadata via LLMDB
  2. **Parameter Validation** - Validates LLM parameters through Zoi schemas
  3. **Credential Resolution** - Finds credentials (per-request > app config > env vars)
  4. **Wire Encoding** - Converts the request into provider-specific JSON
  5. **HTTP Transport** - Sends the request via Tesla (sync or streaming)
  6. **Wire Decoding** - Parses the provider response back into Sycophant structs
  7. **Tool Execution** - Auto-executes tool calls if tools have functions set
  8. **Cost Enrichment** - Calculates token costs from LLMDB pricing data
  9. **Response Validation** - Validates structured output against schema if provided
  10. **Context Attachment** - Stores conversation state for continuation
  """

  require Logger

  alias Sycophant.Auth
  alias Sycophant.Context
  alias Sycophant.Credentials
  alias Sycophant.Error
  alias Sycophant.Message
  alias Sycophant.ModelResolver
  alias Sycophant.Pricing
  alias Sycophant.ResponseValidator
  alias Sycophant.Schema.NormalizedSchema
  alias Sycophant.Schema.Normalizer
  alias Sycophant.StreamChunk
  alias Sycophant.Telemetry
  alias Sycophant.Tool
  alias Sycophant.ToolExecutor
  alias Sycophant.Transport
  alias Sycophant.Usage

  @meta_keys [
    :model,
    :tools,
    :stream,
    :credentials,
    :response_schema,
    :normalized_response_schema,
    :validate,
    :max_steps,
    :auto_execute_tools
  ]

  @doc "Executes a full LLM request pipeline: resolves model, validates params, encodes, transports, and decodes."
  @spec call([Sycophant.Message.t()], keyword()) ::
          {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}
  def call(messages, opts) do
    with {:ok, model_info} <- ModelResolver.resolve(opts[:model]) do
      execute(messages, opts, model_info)
    end
  end

  defp execute(messages, opts, model_info) do
    adapter = model_info.wire_adapter

    with {:ok, opts} <- normalize_schemas(opts),
         {:ok, params} <- validate_params(opts, adapter, model_info),
         {:ok, credentials} <- Credentials.resolve(model_info.provider, opts[:credentials]) do
      telemetry_metadata = build_telemetry_metadata(model_info, opts, params)

      Telemetry.span(telemetry_metadata, fn ->
        run_pipeline(messages, params, opts, model_info, adapter, credentials)
      end)
    end
  end

  defp run_pipeline(messages, params, opts, model_info, adapter, credentials) do
    with {:ok, response} <-
           dispatch_call(messages, params, opts, model_info, adapter, credentials),
         {:ok, response} <-
           maybe_tool_loop(response, opts, params, model_info, adapter, credentials) do
      response = enrich_usage_cost(response, model_info)
      maybe_validate_response(response, opts)
    end
  end

  defp build_telemetry_metadata(model_info, opts, params) do
    %{
      model: "#{model_info.provider}:#{model_info.model_id}",
      provider: model_info.provider,
      wire_protocol: model_info.wire_adapter,
      has_tools?: opts[:tools] != nil and opts[:tools] != [],
      has_stream?: opts[:stream] != nil,
      temperature: params[:temperature],
      top_p: params[:top_p],
      top_k: params[:top_k],
      max_tokens: params[:max_tokens]
    }
  end

  defp maybe_tool_loop(response, opts, params, model_info, adapter, credentials) do
    tools = opts[:tools] || []
    auto_execute? = Keyword.get(opts, :auto_execute_tools, true)

    if auto_execute? and has_executable_tools?(tools) and response.tool_calls != [] do
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

      {_acc, callback} when is_function(callback, 2) ->
        stream_call(messages, params, opts, model_info, adapter, credentials)

      callback when is_function(callback, 1) ->
        stream_call(messages, params, opts, model_info, adapter, credentials)

      other ->
        {:error,
         Error.Invalid.InvalidParams.exception(
           errors: [
             ":stream must be a function/1 or {initial_acc, function/2} tuple, got: #{inspect(other)}"
           ]
         )}
    end
  end

  defp normalize_stream_opt({acc, callback}) when is_function(callback, 2),
    do: {acc, callback}

  defp normalize_stream_opt(callback) when is_function(callback, 1),
    do:
      {nil,
       fn chunk, acc ->
         callback.(chunk)
         acc
       end}

  defp stream_call(messages, params, opts, model_info, adapter, credentials) do
    {acc, callback} = normalize_stream_opt(opts[:stream])

    with {:ok, request} <- build_request(messages, params, opts, model_info),
         {:ok, payload} <- adapter.encode_request(request) do
      transport_type =
        if function_exported?(adapter, :stream_transport, 0),
          do: adapter.stream_transport(),
          else: :sse

      result =
        case transport_type do
          :sse ->
            sse_stream(payload, request, model_info, credentials, adapter, acc, callback)

          :event_stream ->
            binary_stream(payload, request, model_info, credentials, adapter, acc, callback)
        end

      case result do
        {:ok, {:done, response}} ->
          {:ok, attach_context(response, messages, params, opts)}

        {:ok, {:error, _} = error} ->
          error

        {:ok, {:ok, _state, _acc}} ->
          {:error,
           Error.Provider.ResponseInvalid.exception(
             errors: ["Stream ended without a completed response"]
           )}

        {:error, _} = error ->
          error
      end
    end
  end

  defp sse_stream(payload, request, model_info, credentials, adapter, acc, callback) do
    Transport.stream(
      payload,
      transport_opts(model_info, credentials, request),
      fn event_stream ->
        initial_state = adapter.init_stream()
        process_event_stream(event_stream, initial_state, adapter, acc, callback)
      end
    )
  end

  defp binary_stream(payload, request, model_info, credentials, adapter, acc, callback) do
    Transport.stream_binary(
      payload,
      transport_opts(model_info, credentials, request),
      fn binary_stream ->
        initial_state = adapter.init_stream()
        process_binary_stream(binary_stream, <<>>, initial_state, adapter, acc, callback)
      end
    )
  end

  defp process_binary_stream(binary_stream, buffer, state, adapter, acc, callback) do
    stream = if is_binary(binary_stream), do: [binary_stream], else: binary_stream

    Enum.reduce_while(stream, {:ok, buffer, state, acc}, fn chunk, {:ok, buf, st, acc} ->
      data = buf <> chunk

      case process_event_frames(data, st, adapter, acc, callback) do
        {:ok, rest, new_state, new_acc} ->
          {:cont, {:ok, rest, new_state, new_acc}}

        {:done, response} ->
          {:halt, {:done, response}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _buf, final_state, final_acc} -> {:ok, final_state, final_acc}
      {:done, _} = done -> done
      {:error, _} = error -> error
    end
  end

  defp process_event_frames(data, state, adapter, acc, callback) do
    case Sycophant.AWS.EventStream.decode_frame(data) do
      {:ok, raw_event, rest} ->
        event = decode_event_stream_frame(raw_event)

        case adapter.decode_stream_chunk(state, event) do
          {:ok, new_state, chunks} ->
            new_acc = fire_stream_events(chunks, acc, callback)
            process_event_frames(rest, new_state, adapter, new_acc, callback)

          {:done, response} ->
            emit_done(acc, callback)
            {:done, response}

          {:done, response, chunks} ->
            new_acc = fire_stream_events(chunks, acc, callback)
            emit_done(new_acc, callback)
            {:done, response}

          {:terminate, type, error} ->
            emit_terminate(type, error, acc, callback)
            {:error, error}

          {:error, error} = result ->
            emit_terminate(:failed, error, acc, callback)
            result
        end

      {:incomplete, rest} ->
        {:ok, rest, state, acc}

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

  defp process_event_stream(event_stream, initial_state, adapter, acc, callback) do
    Enum.reduce_while(event_stream, {:ok, initial_state, acc}, fn event, {:ok, state, acc} ->
      case decode_sse_data(event) do
        {:ok, decoded_event} ->
          decoded_event
          |> then(&adapter.decode_stream_chunk(state, &1))
          |> handle_stream_chunk(acc, callback)

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp handle_stream_chunk({:ok, new_state, chunks}, acc, callback) do
    new_acc = fire_stream_events(chunks, acc, callback)
    {:cont, {:ok, new_state, new_acc}}
  end

  defp handle_stream_chunk({:done, response}, acc, callback) do
    emit_done(acc, callback)
    {:halt, {:done, response}}
  end

  defp handle_stream_chunk({:done, response, chunks}, acc, callback) do
    new_acc = fire_stream_events(chunks, acc, callback)
    emit_done(new_acc, callback)
    {:halt, {:done, response}}
  end

  defp handle_stream_chunk({:terminate, type, error}, acc, callback) do
    emit_terminate(type, error, acc, callback)
    {:halt, {:error, error}}
  end

  defp handle_stream_chunk({:error, error} = result, acc, callback) do
    emit_terminate(:failed, error, acc, callback)
    {:halt, result}
  end

  defp emit_done(acc, callback) do
    Telemetry.stream_chunk(%StreamChunk{type: :done, data: acc})
    callback.(%StreamChunk{type: :done, data: acc}, acc)
  end

  defp emit_terminate(type, error, acc, callback)
       when type in [:failed, :incomplete, :cancelled] do
    chunk = %StreamChunk{type: type, data: error}
    Telemetry.stream_chunk(chunk)
    callback.(chunk, acc)
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

  defp fire_stream_events(chunks, acc, callback) do
    Enum.reduce(chunks, acc, fn chunk, acc ->
      Telemetry.stream_chunk(chunk)
      callback.(chunk, acc)
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
    case opts[:normalized_response_schema] do
      nil ->
        {:ok, response}

      %NormalizedSchema{} = schema ->
        validate? = Keyword.get(opts, :validate, true)
        ResponseValidator.validate(response, schema, validate?)
    end
  end

  defp normalize_schemas(opts) do
    with {:ok, opts} <- normalize_response_schema(opts) do
      normalize_tool_schemas(opts)
    end
  end

  defp normalize_response_schema(opts) do
    case opts[:response_schema] do
      nil ->
        {:ok, opts}

      %NormalizedSchema{} = normalized ->
        opts =
          opts
          |> Keyword.put(:response_schema, normalized.json_schema)
          |> Keyword.put(:normalized_response_schema, normalized)

        {:ok, opts}

      schema ->
        case Normalizer.normalize(schema) do
          {:ok, normalized} ->
            opts =
              opts
              |> Keyword.put(:response_schema, normalized.json_schema)
              |> Keyword.put(:normalized_response_schema, normalized)

            {:ok, opts}

          {:error, _} = error ->
            error
        end
    end
  end

  defp normalize_tool_schemas(opts) do
    tools = opts[:tools] || []

    case normalize_all_tools(tools) do
      {:ok, normalized} -> {:ok, Keyword.put(opts, :tools, normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_all_tools(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case normalize_tool(tool) do
        {:ok, updated_tool} -> {:cont, {:ok, [updated_tool | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      {:error, _} = error -> error
    end
  end

  defp normalize_tool(%Tool{resolved_schema: %NormalizedSchema{}} = tool), do: {:ok, tool}

  defp normalize_tool(tool) do
    case Normalizer.normalize(tool.parameters) do
      {:ok, normalized} ->
        {:ok,
         %{
           tool
           | parameters: normalized.json_schema,
             schema_source: normalized.source,
             resolved_schema: normalized
         }}

      {:error, _} = error ->
        error
    end
  end

  defp enrich_usage_cost(response, model_info) do
    pricing = get_in(model_info, [:model_struct, Access.key(:pricing)])
    pricing_struct = if pricing, do: Pricing.from_llmdb(pricing), else: nil
    %{response | usage: Usage.calculate_cost(response.usage, pricing_struct)}
  end

  defp attach_context(response, messages, params, opts) do
    assistant_msg = %Message{
      role: :assistant,
      content: build_assistant_content(response),
      tool_calls: if(response.tool_calls in [nil, []], do: nil, else: response.tool_calls)
    }

    context = %Context{
      messages: messages ++ [assistant_msg],
      params: params,
      tools: opts[:tools] || [],
      stream: opts[:stream]
    }

    %{response | context: context}
  end

  defp build_assistant_content(%{reasoning: nil, text: text}), do: text

  defp build_assistant_content(%{reasoning: %{content: [], encrypted_content: nil}, text: text}),
    do: text

  defp build_assistant_content(%{reasoning: reasoning, text: text}) do
    thinking_parts = stamp_reasoning_id(reasoning)

    encrypted_parts =
      if reasoning.encrypted_content,
        do: [%Message.Content.RedactedThinking{data: reasoning.encrypted_content}],
        else: []

    text_parts =
      if text,
        do: [%Message.Content.Text{text: text}],
        else: []

    thinking_parts ++ encrypted_parts ++ text_parts
  end

  defp stamp_reasoning_id(%{id: nil, content: content}), do: content

  defp stamp_reasoning_id(%{id: id, content: [first | rest]}) do
    [%{first | id: id} | rest]
  end

  defp stamp_reasoning_id(%{content: content}), do: content

  defp validate_params(opts, wire_adapter, model_info) do
    raw = opts |> Keyword.drop(@meta_keys) |> Map.new()

    case Zoi.parse(wire_adapter.param_schema(), raw) do
      {:ok, validated} ->
        dropped = Map.keys(raw) -- Map.keys(validated)

        if dropped != [] do
          Logger.warning("Params not supported by #{inspect(wire_adapter)}: #{inspect(dropped)}")
        end

        {:ok, apply_model_constraints(validated, model_info)}

      {:error, errors} ->
        {:error,
         Error.Invalid.InvalidParams.exception(
           errors: Enum.map(errors, &Zoi.prettify_errors([&1]))
         )}
    end
  end

  defp apply_model_constraints(params, model_info) do
    constraints =
      get_in(model_info, [:model_struct, Access.key(:extra, %{}), :constraints]) || %{}

    {final, dropped} =
      Enum.reduce(constraints, {params, []}, fn
        {param, "unsupported"}, {p, d} ->
          if Map.has_key?(p, param), do: {Map.delete(p, param), [param | d]}, else: {p, d}

        _, acc ->
          acc
      end)

    if dropped != [] do
      Logger.warning("Params unsupported by model #{model_info.model_id}: #{inspect(dropped)}")
    end

    final
  end

  defp build_request(messages, params, opts, model_info) do
    model_id = resolve_model_id(model_info, opts)

    {:ok,
     %Sycophant.Request{
       messages: messages,
       model: model_id,
       resolved_model: model_info.model_struct,
       wire_protocol: model_info.wire_adapter,
       params: params,
       tools: opts[:tools] || [],
       stream: opts[:stream],
       response_schema: opts[:response_schema]
     }}
  end

  defp resolve_model_id(model_info, opts) do
    case get_in(opts, [:credentials, :deployment_name]) do
      nil -> model_info.model_id
      name -> name
    end
  end

  defp transport_opts(model_info, credentials, request) do
    base_url = Map.get(credentials, :base_url, model_info.base_url)
    path_params = Auth.path_params_for(model_info.provider, credentials)
    {path_prefix, path_params} = Keyword.pop(path_params, :path_prefix, "")
    path = path_prefix <> model_info.wire_adapter.request_path(request)

    [
      base_url: base_url,
      path: path,
      auth_middlewares: Auth.middlewares_for(model_info.provider, credentials),
      path_params: path_params
    ]
  end
end
