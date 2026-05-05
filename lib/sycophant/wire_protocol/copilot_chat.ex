defmodule Sycophant.WireProtocol.CopilotChat do
  @moduledoc """
  Wire protocol adapter for GitHub Copilot's chat surface.

  Copilot's `/chat/completions` endpoint is OpenAI-Chat-Completions-shaped
  but diverges in two important ways:

    * Copilot exposes assistant reasoning via non-standard `reasoning_text`
      and `reasoning_opaque` fields on the message (sync) and on stream
      deltas. These map to `Sycophant.Reasoning.content` (a single
      `Content.Thinking` block carrying the text) and `:encrypted_content`
      (the opaque blob). During streaming, reasoning fragments are surfaced
      as `:reasoning_delta` chunks. Reasoning content captured from the
      response is never echoed back on subsequent turns - the chat surface
      has no input channel for it.

    * Copilot's stream packs the final text content together with
      `finish_reason: "stop"` in the same SSE frame, where vanilla OpenAI
      sends them in separate frames. `decode_stream_chunk/2` emits any
      chunks generated in the final delta before signalling `:done`, using
      the 3-tuple `{:done, response, chunks}` return shape.
  """

  @behaviour Sycophant.WireProtocol

  alias Sycophant.Context
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Message.Content.Thinking
  alias Sycophant.ParamDefs
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  defmodule StreamState do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct text: "",
              reasoning_text: "",
              reasoning_opaque: nil,
              tool_calls: %{},
              usage: nil,
              model: nil,
              finish_reason: nil
  end

  @param_schema Zoi.map(
                  Map.merge(ParamDefs.shared(), %{
                    seed:
                      Zoi.integer(description: "Random seed for reproducible outputs")
                      |> Zoi.optional(),
                    frequency_penalty:
                      Zoi.float(description: "Penalize repeated tokens")
                      |> Zoi.min(-2.0)
                      |> Zoi.max(2.0)
                      |> Zoi.optional(),
                    presence_penalty:
                      Zoi.float(description: "Penalize tokens already present")
                      |> Zoi.min(-2.0)
                      |> Zoi.max(2.0)
                      |> Zoi.optional()
                  })
                )

  @type t :: unquote(Zoi.type_spec(@param_schema))

  @param_map %{
    temperature: "temperature",
    max_tokens: "max_tokens",
    top_p: "top_p",
    stop: "stop",
    seed: "seed",
    frequency_penalty: "frequency_penalty",
    presence_penalty: "presence_penalty",
    parallel_tool_calls: "parallel_tool_calls"
  }

  @impl true
  def request_path(_request), do: "/chat/completions"

  @impl true
  def stream_transport, do: :sse

  @impl true
  @doc """
  #{Zoi.description(@param_schema)}

  Options:

  #{Zoi.describe(@param_schema)}
  """
  def param_schema, do: @param_schema

  @impl true
  def encode_request(%Request{} = request) do
    with {:ok, messages} <- encode_messages(request.messages) do
      build_payload(request, messages)
    end
  end

  @impl true
  def encode_tools(tools) when is_list(tools) do
    {:ok, Enum.map(tools, &encode_tool/1)}
  end

  @impl true
  def encode_response_schema(schema) do
    {:ok,
     %{
       "type" => "json_schema",
       "json_schema" => %{
         "name" => "response",
         "strict" => true,
         "schema" => set_strict_additional_properties(schema)
       }
     }}
  end

  @impl true
  def decode_response(%{"choices" => [%{"message" => message} | _]} = body) do
    with {:ok, tool_calls} <- decode_tool_calls(message["tool_calls"]) do
      response = %Response{
        text: message["content"],
        tool_calls: tool_calls,
        reasoning: decode_reasoning(message),
        finish_reason:
          map_finish_reason(get_in(body, ["choices", Access.at(0), "finish_reason"])),
        usage: decode_usage(body["usage"]),
        model: body["model"],
        raw: body,
        context: %Context{messages: []}
      }

      {:ok, response}
    end
  end

  def decode_response(body), do: {:error, ResponseInvalid.exception(raw: body)}

  @impl true
  def init_stream, do: %StreamState{}

  @impl true
  def decode_stream_chunk(state, %{data: "[DONE]"}), do: {:ok, state, []}

  def decode_stream_chunk(_state, %{data: %{"error" => error}}) when is_map(error) do
    {:terminate, :failed, decode_stream_error(error)}
  end

  def decode_stream_chunk(state, %{
        data: %{"choices" => [%{"delta" => delta} = choice | _]} = body
      }) do
    state = maybe_capture_model(state, body)
    state = maybe_capture_usage(state, body)

    {state, chunks} = process_delta(state, delta)

    case choice["finish_reason"] do
      reason when reason in ["stop", "tool_calls", "length", "content_filter"] ->
        {:done, build_streamed_response(%{state | finish_reason: reason}), chunks}

      _ ->
        {:ok, state, chunks}
    end
  end

  def decode_stream_chunk(state, _event), do: {:ok, state, []}

  # --- Reasoning ---

  defp decode_reasoning(%{"reasoning_text" => text} = msg) when is_binary(text) and text != "" do
    %Reasoning{
      content: [%Thinking{text: text}],
      encrypted_content: msg["reasoning_opaque"]
    }
  end

  defp decode_reasoning(%{"reasoning_opaque" => opaque} = _msg)
       when is_binary(opaque) and opaque != "" do
    %Reasoning{content: [], encrypted_content: opaque}
  end

  defp decode_reasoning(_msg), do: nil

  # --- Streaming helpers ---

  defp maybe_capture_model(state, %{"model" => model}) when is_binary(model),
    do: %{state | model: model}

  defp maybe_capture_model(state, _body), do: state

  defp maybe_capture_usage(state, %{
         "usage" => %{"prompt_tokens" => input, "completion_tokens" => output} = usage
       }) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"])
    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"])

    %{
      state
      | usage: %Usage{
          input_tokens: input,
          output_tokens: output,
          cache_read_input_tokens: cached,
          reasoning_tokens: reasoning
        }
    }
  end

  defp maybe_capture_usage(state, _body), do: state

  defp process_delta(state, delta) when is_map(delta) do
    {state, reasoning_chunks} = process_reasoning_delta(state, delta)
    {state, content_chunks} = process_content_delta(state, delta)
    {state, tool_chunks} = process_tool_call_deltas(state, delta)
    {state, reasoning_chunks ++ content_chunks ++ tool_chunks}
  end

  defp process_delta(state, _delta), do: {state, []}

  defp process_reasoning_delta(state, %{"reasoning_text" => text})
       when is_binary(text) and text != "" do
    state = %{state | reasoning_text: state.reasoning_text <> text}
    {state, [%StreamChunk{type: :reasoning_delta, data: text}]}
  end

  defp process_reasoning_delta(state, %{"reasoning_opaque" => opaque})
       when is_binary(opaque) and opaque != "" do
    {%{state | reasoning_opaque: opaque}, []}
  end

  defp process_reasoning_delta(state, _delta), do: {state, []}

  defp process_content_delta(state, %{"content" => content})
       when is_binary(content) and content != "" do
    {%{state | text: state.text <> content}, [%StreamChunk{type: :text_delta, data: content}]}
  end

  defp process_content_delta(state, _delta), do: {state, []}

  defp process_tool_call_deltas(state, %{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.reduce(tool_calls, {state, []}, fn tc_delta, {acc_state, acc_chunks} ->
      index = tc_delta["index"]
      existing = Map.get(acc_state.tool_calls, index)

      {updated_tc, chunk_data} = merge_tool_call_delta(existing, tc_delta)

      new_state = %{acc_state | tool_calls: Map.put(acc_state.tool_calls, index, updated_tc)}
      chunk = %StreamChunk{type: :tool_call_delta, data: chunk_data, index: index}
      {new_state, acc_chunks ++ [chunk]}
    end)
  end

  defp process_tool_call_deltas(state, _delta), do: {state, []}

  defp merge_tool_call_delta(nil, tc_delta) do
    func = tc_delta["function"] || %{}

    tc = %{
      id: tc_delta["id"],
      name: func["name"],
      arguments: func["arguments"] || ""
    }

    {tc, %{id: tc.id, name: tc.name, arguments_delta: func["arguments"] || ""}}
  end

  defp merge_tool_call_delta(existing, tc_delta) do
    func = tc_delta["function"] || %{}
    args_delta = func["arguments"] || ""
    name = func["name"] || existing.name

    updated = %{existing | arguments: existing.arguments <> args_delta, name: name}
    {updated, %{id: existing.id, name: name, arguments_delta: args_delta}}
  end

  defp build_streamed_response(state) do
    tool_calls = assemble_tool_calls(state.tool_calls)
    text = if state.text == "", do: nil, else: state.text

    %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: build_streamed_reasoning(state),
      finish_reason: map_finish_reason(state.finish_reason),
      usage: state.usage,
      model: state.model,
      context: %Context{messages: []}
    }
  end

  defp build_streamed_reasoning(%StreamState{reasoning_text: "", reasoning_opaque: nil}), do: nil

  defp build_streamed_reasoning(%StreamState{reasoning_text: text, reasoning_opaque: opaque}) do
    content =
      if text == "",
        do: [],
        else: [%Thinking{text: text}]

    %Reasoning{content: content, encrypted_content: opaque}
  end

  defp assemble_tool_calls(tool_calls_map) when map_size(tool_calls_map) == 0, do: []

  defp assemble_tool_calls(tool_calls_map) do
    tool_calls_map
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, tc} ->
      case JSON.decode(tc.arguments) do
        {:ok, args} -> %ToolCall{id: tc.id, name: tc.name, arguments: args}
        {:error, _} -> %ToolCall{id: tc.id, name: tc.name, arguments: %{}}
      end
    end)
  end

  # --- Response decoding helpers ---

  defp decode_tool_calls(nil), do: {:ok, []}

  defp decode_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tc, {:ok, acc} ->
      case decode_single_tool_call(tc) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end)
  end

  defp decode_single_tool_call(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => args}
       })
       when is_binary(args) do
    case JSON.decode(args) do
      {:ok, decoded} ->
        {:ok, %ToolCall{id: id, name: name, arguments: decoded}}

      {:error, _} ->
        {:error,
         ResponseInvalid.exception(
           errors: ["Failed to decode tool call arguments for #{name}: #{args}"]
         )}
    end
  end

  defp decode_single_tool_call(tc) do
    {:error, ResponseInvalid.exception(errors: ["Malformed tool call: #{inspect(tc)}"])}
  end

  defp decode_usage(%{"prompt_tokens" => input, "completion_tokens" => output} = usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"])
    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"])

    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached,
      reasoning_tokens: reasoning
    }
  end

  defp decode_usage(_), do: nil

  # --- Message Encoding ---

  defp encode_messages(messages) do
    {:ok, Enum.map(messages, &encode_message/1)}
  end

  defp encode_message(%Message{role: :tool_result, content: content, tool_call_id: id}) do
    %{"role" => "tool", "tool_call_id" => id, "content" => to_string(content)}
  end

  defp encode_message(%Message{role: role, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    %{
      "role" => encode_role(role),
      "content" => encode_content(content),
      "tool_calls" => Enum.map(tool_calls, &encode_tool_call/1)
    }
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => encode_role(role), "content" => encode_content(content)}
  end

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"
  defp encode_role(:system), do: "system"

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(nil), do: nil

  defp encode_content(parts) when is_list(parts) do
    case parts |> Enum.map(&encode_content_part/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      encoded -> encoded
    end
  end

  defp encode_content_part(%Content.Text{text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp encode_content_part(%Content.Image{url: url}) when is_binary(url) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}
  end

  defp encode_content_part(%Content.Thinking{}), do: nil
  defp encode_content_part(%Content.RedactedThinking{}), do: nil

  defp encode_tool_call(%ToolCall{id: id, name: name, arguments: args}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => JSON.encode!(args)}
    }
  end

  # --- Tool Encoding ---

  defp encode_tool(%Tool{
         name: name,
         description: description,
         parameters: parameters,
         strict: strict
       }) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => set_strict_additional_properties(parameters),
        "strict" => strict
      }
    }
  end

  # --- Param Translation ---

  defp translate_params(params) when is_map(params) do
    Enum.reduce(@param_map, %{}, fn {canonical, wire_key}, acc ->
      case Map.get(params, canonical) do
        nil -> acc
        value -> Map.put(acc, wire_key, value)
      end
    end)
  end

  # --- Payload Assembly ---

  defp build_payload(request, messages) do
    base = %{"model" => request.model, "messages" => messages}

    with {:ok, payload} <- maybe_put_tools(base, request.tools),
         {:ok, payload} <- maybe_put_response_format(payload, request.response_schema) do
      {:ok,
       payload
       |> maybe_put_stream(request.stream)
       |> maybe_put_tool_choice(request.params)
       |> Map.merge(translate_params(request.params))}
    end
  end

  defp maybe_put_stream(payload, nil), do: payload

  defp maybe_put_stream(payload, _stream) do
    payload
    |> Map.put("stream", true)
    |> Map.put("stream_options", %{"include_usage" => true})
  end

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    {:ok, encoded} = encode_tools(tools)
    {:ok, Map.put(payload, "tools", encoded)}
  end

  defp maybe_put_tool_choice(payload, %{tool_choice: :auto}),
    do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, %{tool_choice: :none}),
    do: Map.put(payload, "tool_choice", "none")

  defp maybe_put_tool_choice(payload, %{tool_choice: :any}),
    do: Map.put(payload, "tool_choice", "required")

  defp maybe_put_tool_choice(payload, %{tool_choice: {:tool, name}}) do
    Map.put(payload, "tool_choice", %{"type" => "function", "function" => %{"name" => name}})
  end

  defp maybe_put_tool_choice(payload, _), do: payload

  defp maybe_put_response_format(payload, nil), do: {:ok, payload}

  defp maybe_put_response_format(payload, schema) do
    {:ok, format} = encode_response_schema(schema)
    {:ok, Map.put(payload, "response_format", format)}
  end

  defp set_strict_additional_properties(%{"type" => "object", "properties" => props} = schema) do
    updated_props = Map.new(props, fn {k, v} -> {k, set_strict_additional_properties(v)} end)

    schema
    |> Map.put("properties", updated_props)
    |> Map.put("additionalProperties", false)
  end

  defp set_strict_additional_properties(%{"type" => "object"} = schema) do
    Map.put(schema, "additionalProperties", false)
  end

  defp set_strict_additional_properties(%{"type" => "array", "items" => items} = schema) do
    Map.put(schema, "items", set_strict_additional_properties(items))
  end

  defp set_strict_additional_properties(schema), do: schema

  # --- Errors and finish reasons ---

  defp decode_stream_error(%{"type" => "server_error", "message" => msg}) do
    Sycophant.Error.Provider.ServerError.exception(body: msg)
  end

  defp decode_stream_error(%{"code" => "rate_limit_exceeded"}) do
    Sycophant.Error.Provider.RateLimited.exception([])
  end

  defp decode_stream_error(%{"type" => type, "message" => msg}) do
    ResponseInvalid.exception(errors: ["#{type}: #{msg}"])
  end

  defp decode_stream_error(%{"message" => msg}) do
    ResponseInvalid.exception(errors: [msg])
  end

  defp decode_stream_error(error) do
    ResponseInvalid.exception(errors: ["Stream error: #{inspect(error)}"])
  end

  defp map_finish_reason("stop"), do: :stop
  defp map_finish_reason("tool_calls"), do: :tool_use
  defp map_finish_reason("function_call"), do: :tool_use
  defp map_finish_reason("length"), do: :max_tokens
  defp map_finish_reason("content_filter"), do: :content_filter
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
