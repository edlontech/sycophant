defmodule Sycophant.WireProtocol.AnthropicMessages do
  @moduledoc """
  Wire protocol adapter for the Anthropic Messages API format.

  Encodes Sycophant Request structs into the `/v1/messages`
  JSON format and decodes responses back into Response structs.
  """

  @behaviour Sycophant.WireProtocol

  @impl true
  def request_path(_request), do: "/v1/messages"

  @impl true
  def stream_transport, do: :sse

  alias Sycophant.Context
  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.ParamDefs
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.Schema.JsonSchema
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  defmodule StreamState do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct text: "",
              tool_calls: %{},
              thinking: "",
              encrypted_thinking: nil,
              usage: nil,
              model: nil,
              current_block: nil,
              stop_reason: nil
  end

  @param_schema Zoi.map(
                  Map.merge(ParamDefs.shared(), %{
                    speed:
                      Zoi.enum([:standard, :fast],
                        description: "Inference speed mode"
                      )
                      |> Zoi.optional()
                  })
                )

  @impl true
  def param_schema, do: @param_schema

  @param_map %{
    temperature: "temperature",
    max_tokens: "max_tokens",
    top_p: "top_p",
    top_k: "top_k",
    stop: "stop_sequences",
    service_tier: "service_tier"
  }

  @reasoning_budgets %{
    minimal: 1024,
    low: 1024,
    medium: 4096,
    high: 16_384,
    xhigh: 32_768
  }

  # --- encode_request ---

  @impl true
  def encode_request(%Request{} = request) do
    {system_text, non_system} = split_system_messages(request.messages)

    with {:ok, messages} <- encode_messages(non_system) do
      build_payload(request, system_text, messages)
    end
  end

  # --- encode_tools ---

  @impl true
  def encode_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case encode_tool(tool) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end)
  end

  # --- encode_response_schema ---

  @impl true
  def encode_response_schema(schema) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(schema) do
      {:ok, set_additional_properties_false(json_schema)}
    end
  end

  # --- decode_response ---

  @impl true
  def decode_response(%{"type" => "error", "error" => error}) do
    {:error, decode_api_error(error)}
  end

  def decode_response(%{"type" => "message", "content" => content} = body) do
    {text, tool_calls, reasoning} = process_content_blocks(content)

    response = %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      finish_reason: map_finish_reason(body["stop_reason"]),
      usage: decode_usage(body["usage"]),
      model: body["model"],
      raw: body,
      context: %Context{messages: []}
    }

    {:ok, response}
  end

  def decode_response(body) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  # --- init_stream ---

  @impl true
  def init_stream, do: %StreamState{}

  # --- decode_stream_chunk ---

  @impl true
  def decode_stream_chunk(state, %{event: "message_start", data: %{"message" => message}}) do
    state = %{state | model: message["model"]}

    state =
      case message["usage"] do
        %{"input_tokens" => input} ->
          %{state | usage: %Usage{input_tokens: input, output_tokens: 0}}

        _ ->
          state
      end

    {:ok, state, []}
  end

  def decode_stream_chunk(state, %{
        event: "content_block_start",
        data: %{
          "index" => index,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
        }
      }) do
    state = %{
      state
      | current_block: {:tool_use, index},
        tool_calls: Map.put(state.tool_calls, index, %{id: id, name: name, arguments: ""})
    }

    {:ok, state, []}
  end

  def decode_stream_chunk(state, %{
        event: "content_block_start",
        data: %{"index" => index, "content_block" => %{"type" => type}}
      }) do
    {:ok, %{state | current_block: {String.to_existing_atom(type), index}}, []}
  end

  def decode_stream_chunk(state, %{
        event: "content_block_delta",
        data: %{"delta" => %{"type" => "text_delta", "text" => text}}
      }) do
    state = %{state | text: state.text <> text}
    {:ok, state, [%StreamChunk{type: :text_delta, data: text}]}
  end

  def decode_stream_chunk(state, %{
        event: "content_block_delta",
        data: %{
          "index" => index,
          "delta" => %{"type" => "input_json_delta", "partial_json" => json}
        }
      }) do
    tc = Map.fetch!(state.tool_calls, index)
    updated_tc = %{tc | arguments: tc.arguments <> json}
    state = %{state | tool_calls: Map.put(state.tool_calls, index, updated_tc)}

    chunk = %StreamChunk{
      type: :tool_call_delta,
      data: %{id: tc.id, name: tc.name, arguments_delta: json},
      index: index
    }

    {:ok, state, [chunk]}
  end

  def decode_stream_chunk(state, %{
        event: "content_block_delta",
        data: %{"delta" => %{"type" => "thinking_delta", "thinking" => thinking}}
      }) do
    state = %{state | thinking: state.thinking <> thinking}
    {:ok, state, [%StreamChunk{type: :reasoning_delta, data: thinking}]}
  end

  def decode_stream_chunk(state, %{event: "content_block_stop", data: _}) do
    {:ok, %{state | current_block: nil}, []}
  end

  def decode_stream_chunk(state, %{event: "message_delta", data: data}) do
    state =
      case data["usage"] do
        %{"output_tokens" => output} when not is_nil(state.usage) ->
          %{state | usage: %{state.usage | output_tokens: output}}

        _ ->
          state
      end

    state =
      case get_in(data, ["delta", "stop_reason"]) do
        nil -> state
        reason -> %{state | stop_reason: reason}
      end

    {:ok, state, []}
  end

  def decode_stream_chunk(state, %{event: "message_stop", data: _}) do
    {:done, build_streamed_response(state)}
  end

  def decode_stream_chunk(state, _event), do: {:ok, state, []}

  # --- Private: System Message Splitting ---

  defp split_system_messages(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &(&1.role == :system))

    system_text =
      case system_msgs do
        [] ->
          nil

        msgs ->
          joined =
            msgs
            |> Enum.map(& &1.content)
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> Enum.join("\n")

          if joined == "", do: nil, else: joined
      end

    {system_text, rest}
  end

  # --- Private: Message Encoding ---

  defp encode_messages(messages) do
    {:ok, messages |> group_tool_results() |> Enum.map(&encode_message/1)}
  end

  defp group_tool_results(messages) do
    messages
    |> Enum.chunk_while(
      [],
      fn
        %Message{role: :tool_result} = msg, acc -> {:cont, [msg | acc]}
        msg, [] -> {:cont, msg, []}
        msg, acc -> {:cont, Enum.reverse(acc), [msg]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.flat_map(fn
      list when is_list(list) and list != [] -> [{:tool_result_group, list}]
      %Message{} = msg -> [msg]
      [] -> []
    end)
  end

  defp encode_message({:tool_result_group, results}) do
    content =
      Enum.map(results, fn %Message{tool_call_id: id, content: c} ->
        %{"type" => "tool_result", "tool_use_id" => id, "content" => to_string(c)}
      end)

    %{"role" => "user", "content" => content}
  end

  defp encode_message(%Message{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    text_blocks =
      case content do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
      end

    tool_use_blocks =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => args}
      end)

    %{"role" => "assistant", "content" => text_blocks ++ tool_use_blocks}
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => encode_role(role), "content" => encode_content(content)}
  end

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(nil), do: nil

  defp encode_content(parts) when is_list(parts) do
    Enum.map(parts, &encode_content_part/1)
  end

  defp encode_content_part(%Content.Text{text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp encode_content_part(%Content.Image{url: url}) when is_binary(url) do
    %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
  end

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
    }
  end

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(parameters) do
      {:ok, %{"name" => name, "description" => description, "input_schema" => json_schema}}
    end
  end

  # --- Private: Response Decoding ---

  defp process_content_blocks(content) do
    Enum.reduce(content, {[], [], nil}, fn block, {texts, tcs, reasoning} ->
      case block do
        %{"type" => "text", "text" => text} ->
          {[text | texts], tcs, reasoning}

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          tc = %ToolCall{id: id, name: name, arguments: input}
          {texts, [tc | tcs], reasoning}

        %{"type" => "thinking", "thinking" => thinking} ->
          {texts, tcs, %Reasoning{summary: thinking}}

        %{"type" => "redacted_thinking", "data" => data} ->
          {texts, tcs, %Reasoning{encrypted_content: data}}

        _ ->
          {texts, tcs, reasoning}
      end
    end)
    |> then(fn {texts, tcs, reasoning} ->
      text =
        case Enum.reverse(texts) do
          [] -> nil
          parts -> Enum.join(parts, "")
        end

      {text, Enum.reverse(tcs), reasoning}
    end)
  end

  defp decode_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"],
      cache_read_input_tokens: usage["cache_read_input_tokens"]
    }
  end

  defp decode_usage(_), do: nil

  defp decode_api_error(%{"type" => type, "message" => msg})
       when type in ["overloaded_error", "api_error"] do
    ServerError.exception(body: msg)
  end

  defp decode_api_error(%{"type" => "rate_limit_error"}) do
    RateLimited.exception([])
  end

  defp decode_api_error(%{"type" => _type, "message" => msg}) do
    ResponseInvalid.exception(errors: [msg])
  end

  defp decode_api_error(error) do
    ResponseInvalid.exception(errors: ["Unknown error: #{inspect(error)}"])
  end

  # --- Private: Param Translation ---

  defp translate_params(params) when is_map(params) do
    base =
      Enum.reduce(@param_map, %{}, fn {canonical, wire_key}, acc ->
        case Map.get(params, canonical) do
          nil -> acc
          value -> Map.put(acc, wire_key, value)
        end
      end)

    maybe_put_speed(base, params)
  end

  defp maybe_put_speed(payload, %{speed: speed}) when speed in [:standard, :fast] do
    Map.put(payload, "speed", Atom.to_string(speed))
  end

  defp maybe_put_speed(payload, _), do: payload

  # --- Private: Payload Assembly ---

  defp build_payload(request, system_text, messages) do
    base = %{"model" => request.model, "messages" => messages}
    base = if system_text, do: Map.put(base, "system", system_text), else: base

    with {:ok, payload} <- maybe_put_tools(base, request.tools),
         {:ok, payload} <- maybe_put_response_format(payload, request.response_schema) do
      payload =
        payload
        |> maybe_put_stream(request.stream)
        |> maybe_put_tool_choice(request.params)
        |> Map.merge(translate_params(request.params))
        |> ensure_max_tokens(request.params)
        |> maybe_put_thinking(request.params)

      {:ok, payload}
    end
  end

  defp ensure_max_tokens(payload, %{max_tokens: max}) when is_integer(max), do: payload
  defp ensure_max_tokens(payload, _), do: Map.put_new(payload, "max_tokens", 4096)

  defp maybe_put_stream(payload, nil), do: payload
  defp maybe_put_stream(payload, _callback), do: Map.put(payload, "stream", true)

  defp maybe_put_tool_choice(payload, %{tool_choice: :auto}),
    do: Map.put(payload, "tool_choice", %{"type" => "auto"})

  defp maybe_put_tool_choice(payload, %{tool_choice: :none}),
    do: Map.put(payload, "tool_choice", %{"type" => "none"})

  defp maybe_put_tool_choice(payload, %{tool_choice: :any}),
    do: Map.put(payload, "tool_choice", %{"type" => "any"})

  defp maybe_put_tool_choice(payload, %{tool_choice: {:tool, name}}) do
    Map.put(payload, "tool_choice", %{"type" => "tool", "name" => name})
  end

  defp maybe_put_tool_choice(payload, _), do: payload

  defp maybe_put_thinking(payload, %{reasoning: :none}) do
    Map.put(payload, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(payload, %{reasoning: level})
       when is_map_key(@reasoning_budgets, level) do
    budget = Map.fetch!(@reasoning_budgets, level)
    Map.put(payload, "thinking", %{"type" => "enabled", "budget_tokens" => budget})
  end

  defp maybe_put_thinking(payload, _), do: payload

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    case encode_tools(tools) do
      {:ok, encoded} -> {:ok, Map.put(payload, "tools", encoded)}
      {:error, _} = err -> err
    end
  end

  defp set_additional_properties_false(%{"type" => "object", "properties" => props} = schema) do
    updated = Map.new(props, fn {k, v} -> {k, set_additional_properties_false(v)} end)

    schema
    |> Map.put("properties", updated)
    |> Map.put("additionalProperties", false)
  end

  defp set_additional_properties_false(%{"type" => "array", "items" => items} = schema) do
    Map.put(schema, "items", set_additional_properties_false(items))
  end

  defp set_additional_properties_false(schema), do: schema

  defp maybe_put_response_format(payload, nil), do: {:ok, payload}

  defp maybe_put_response_format(payload, schema) do
    case encode_response_schema(schema) do
      {:ok, json_schema} ->
        {:ok,
         Map.put(payload, "output_config", %{
           "format" => %{"type" => "json_schema", "schema" => json_schema}
         })}

      {:error, _} = err ->
        err
    end
  end

  # --- Private: Streaming ---

  defp build_streamed_response(state) do
    tool_calls = assemble_tool_calls(state.tool_calls)
    text = if state.text == "", do: nil, else: state.text

    reasoning =
      cond do
        state.encrypted_thinking != nil ->
          %Reasoning{encrypted_content: state.encrypted_thinking}

        state.thinking != "" ->
          %Reasoning{summary: state.thinking}

        true ->
          nil
      end

    %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      finish_reason: map_finish_reason(state.stop_reason),
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

  # --- Private: Finish Reason Mapping ---

  defp map_finish_reason("end_turn"), do: :stop
  defp map_finish_reason("tool_use"), do: :tool_use
  defp map_finish_reason("max_tokens"), do: :max_tokens
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
