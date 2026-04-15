defmodule Sycophant.WireProtocol.OpenAICompletions do
  @moduledoc """
  Wire protocol adapter for the OpenAI Chat Completions API format.

  Encodes Sycophant Request structs into the `/v1/chat/completions`
  JSON format and decodes responses back into Response structs.
  Used by any provider that implements the OpenAI-compatible API
  (OpenAI, OpenRouter, Together, DeepInfra, etc.).
  """

  @behaviour Sycophant.WireProtocol

  @impl true
  def request_path(_request), do: "/chat/completions"

  @impl true
  def stream_transport, do: :sse

  alias Sycophant.Context
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.ParamDefs
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  defmodule StreamState do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct text: "", tool_calls: %{}, usage: nil, model: nil, finish_reason: nil
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
                      |> Zoi.optional(),
                    logprobs:
                      Zoi.boolean(description: "Return log probabilities of output tokens")
                      |> Zoi.optional(),
                    top_logprobs:
                      Zoi.integer(description: "Number of most likely tokens to return")
                      |> Zoi.optional()
                  })
                )

  @type t :: unquote(Zoi.type_spec(@param_schema))

  @impl true
  @doc """
  #{Zoi.description(@param_schema)}

  Options:

  #{Zoi.describe(@param_schema)}
  """
  def param_schema, do: @param_schema

  @param_map %{
    temperature: "temperature",
    max_tokens: "max_completion_tokens",
    top_p: "top_p",
    stop: "stop",
    seed: "seed",
    frequency_penalty: "frequency_penalty",
    presence_penalty: "presence_penalty",
    parallel_tool_calls: "parallel_tool_calls",
    service_tier: "service_tier",
    logprobs: "logprobs",
    top_logprobs: "top_logprobs"
  }

  @impl true
  def encode_request(%Request{} = request) do
    with {:ok, messages} <- encode_messages(request.messages) do
      build_payload(request, messages)
    end
  end

  @impl true
  def encode_tools(tools) when is_list(tools) do
    {:ok,
     Enum.map(tools, fn tool ->
       {:ok, encoded} = encode_tool(tool)
       encoded
     end)}
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

  def decode_response(body) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  @impl true
  def init_stream, do: %StreamState{}

  @impl true
  def decode_stream_chunk(state, %{data: "[DONE]"}), do: {:ok, state, []}

  def decode_stream_chunk(state, %{
        data: %{"choices" => [%{"delta" => delta} = choice | _]} = body
      }) do
    state = maybe_capture_model(state, body)
    state = maybe_capture_usage(state, body)

    {state, chunks} = process_delta(state, delta)

    case choice["finish_reason"] do
      reason when reason in ["stop", "tool_calls", "length", "content_filter"] ->
        {:done, build_streamed_response(%{state | finish_reason: reason})}

      _ ->
        {:ok, state, chunks}
    end
  end

  def decode_stream_chunk(state, _event), do: {:ok, state, []}

  # --- Streaming Helpers ---

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

  defp process_delta(state, %{"content" => content} = delta) when is_binary(content) do
    state = %{state | text: state.text <> content}
    chunk = %StreamChunk{type: :text_delta, data: content}
    {state, tc_chunks} = process_tool_call_deltas(state, delta)
    {state, [chunk | tc_chunks]}
  end

  defp process_delta(state, %{"tool_calls" => _} = delta) do
    process_tool_call_deltas(state, delta)
  end

  defp process_delta(state, _delta), do: {state, []}

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
      finish_reason: map_finish_reason(state.finish_reason),
      usage: state.usage,
      model: state.model,
      context: %Context{messages: []}
    }
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

  # --- Response Decoding Helpers ---

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
    Enum.map(parts, &encode_content_part/1)
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
    {:ok,
     %{
       "type" => "function",
       "function" => %{
         "name" => name,
         "description" => description,
         "parameters" => set_strict_additional_properties(parameters),
         "strict" => strict
       }
     }}
  end

  # --- Param Translation ---

  defp translate_params(params) when is_map(params) do
    base =
      Enum.reduce(@param_map, %{}, fn {canonical, wire_key}, acc ->
        case Map.get(params, canonical) do
          nil -> acc
          value -> Map.put(acc, wire_key, value)
        end
      end)

    base
    |> maybe_put_reasoning_effort(params)
    |> maybe_put_reasoning_summary(params)
  end

  defp maybe_put_reasoning_effort(payload, %{reasoning_effort: level}) when not is_nil(level),
    do: Map.put(payload, "reasoning_effort", stringify_atom(level))

  defp maybe_put_reasoning_effort(payload, _), do: payload

  defp maybe_put_reasoning_summary(payload, %{reasoning_summary: value}) when not is_nil(value),
    do: Map.put(payload, "reasoning_summary", stringify_atom(value))

  defp maybe_put_reasoning_summary(payload, _), do: payload

  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value), do: value

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

  defp set_strict_additional_properties(%{"type" => "array", "items" => items} = schema) do
    Map.put(schema, "items", set_strict_additional_properties(items))
  end

  defp set_strict_additional_properties(schema), do: schema

  # --- Finish Reason Mapping ---

  defp map_finish_reason("stop"), do: :stop
  defp map_finish_reason("tool_calls"), do: :tool_use
  defp map_finish_reason("function_call"), do: :tool_use
  defp map_finish_reason("length"), do: :max_tokens
  defp map_finish_reason("content_filter"), do: :content_filter
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
