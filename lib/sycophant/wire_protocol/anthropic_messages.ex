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
    {:ok,
     Enum.map(tools, fn tool ->
       {:ok, encoded} = encode_tool(tool)
       encoded
     end)}
  end

  # --- encode_response_schema ---

  @impl true
  def encode_response_schema(schema) do
    {:ok, set_additional_properties_false(schema)}
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
            |> Enum.map(&system_message_text/1)
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> Enum.join("\n")

          if joined == "", do: nil, else: joined
      end

    {system_text, rest}
  end

  defp system_message_text(%Message{content: content}) when is_binary(content), do: content
  defp system_message_text(%Message{content: nil}), do: nil

  defp system_message_text(%Message{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %Content.Text{text: text} -> text
      _ -> nil
    end)
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n")
  end

  # --- Private: Message Encoding ---

  defp encode_messages(messages) do
    {:ok, messages |> group_tool_results() |> Enum.map(&encode_message/1)}
  end

  defp group_tool_results(messages) do
    {acc, group} =
      Enum.reduce(messages, {[], []}, fn
        %Message{role: :tool_result} = msg, {acc, group} ->
          {acc, [msg | group]}

        msg, {acc, []} ->
          {[msg | acc], []}

        msg, {acc, group} ->
          {[msg, {:tool_result_group, Enum.reverse(group)} | acc], []}
      end)

    final =
      case group do
        [] -> acc
        _ -> [{:tool_result_group, Enum.reverse(group)} | acc]
      end

    Enum.reverse(final)
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
    content_blocks = encode_assistant_content_blocks(content)

    tool_use_blocks =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => args}
      end)

    %{"role" => "assistant", "content" => content_blocks ++ tool_use_blocks}
  end

  defp encode_message(%Message{role: :assistant, content: content}) do
    %{"role" => "assistant", "content" => encode_content(content)}
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

  defp encode_content_part(%Content.Thinking{text: text, signature: signature}) do
    block = %{"type" => "thinking", "thinking" => text}
    if signature, do: Map.put(block, "signature", signature), else: block
  end

  defp encode_content_part(%Content.RedactedThinking{data: data}) do
    %{"type" => "redacted_thinking", "data" => data}
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

  defp encode_assistant_content_blocks(nil), do: []
  defp encode_assistant_content_blocks(""), do: []

  defp encode_assistant_content_blocks(text) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp encode_assistant_content_blocks(parts) when is_list(parts),
    do: Enum.map(parts, &encode_content_part/1)

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{
         name: name,
         description: description,
         parameters: parameters,
         strict: strict
       }) do
    tool = %{"name" => name, "description" => description, "input_schema" => parameters}
    {:ok, if(strict, do: Map.put(tool, "strict", true), else: tool)}
  end

  # --- Private: Response Decoding ---

  defp process_content_blocks(content) do
    {texts, tcs, thinking, encrypted} =
      Enum.reduce(content, {[], [], [], nil}, &classify_content_block/2)

    text =
      case Enum.reverse(texts) do
        [] -> nil
        parts -> Enum.join(parts, "")
      end

    reasoning =
      case {thinking, encrypted} do
        {[], nil} -> nil
        _ -> %Reasoning{content: Enum.reverse(thinking), encrypted_content: encrypted}
      end

    {text, Enum.reverse(tcs), reasoning}
  end

  defp classify_content_block(%{"type" => "text", "text" => text}, {texts, tcs, th, enc}),
    do: {[text | texts], tcs, th, enc}

  defp classify_content_block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input},
         {texts, tcs, th, enc}
       ),
       do: {texts, [%ToolCall{id: id, name: name, arguments: input} | tcs], th, enc}

  defp classify_content_block(
         %{"type" => "thinking", "thinking" => t} = b,
         {texts, tcs, th, enc}
       ),
       do: {texts, tcs, [%Content.Thinking{text: t, signature: b["signature"]} | th], enc}

  defp classify_content_block(
         %{"type" => "redacted_thinking", "data" => data},
         {texts, tcs, th, _}
       ),
       do: {texts, tcs, th, data}

  defp classify_content_block(_, acc), do: acc

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

  defp maybe_put_thinking(payload, %{reasoning_effort: :none}) do
    Map.put(payload, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(payload, %{reasoning_effort: level})
       when is_map_key(@reasoning_budgets, level) do
    budget = Map.fetch!(@reasoning_budgets, level)
    Map.put(payload, "thinking", %{"type" => "enabled", "budget_tokens" => budget})
  end

  defp maybe_put_thinking(payload, _), do: payload

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    {:ok, encoded} = encode_tools(tools)
    {:ok, Map.put(payload, "tools", encoded)}
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
    {:ok, json_schema} = encode_response_schema(schema)

    {:ok,
     Map.put(payload, "output_config", %{
       "format" => %{"type" => "json_schema", "schema" => json_schema}
     })}
  end

  # --- Private: Streaming ---

  defp build_streamed_response(state) do
    tool_calls = assemble_tool_calls(state.tool_calls)
    text = if state.text == "", do: nil, else: state.text

    reasoning =
      case {state.thinking, state.encrypted_thinking} do
        {"", nil} ->
          nil

        {thinking, encrypted} ->
          %Reasoning{
            content:
              if(thinking == "",
                do: [],
                else: [%Content.Thinking{text: thinking}]
              ),
            encrypted_content: encrypted
          }
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
