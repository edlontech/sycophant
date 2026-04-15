defmodule Sycophant.WireProtocol.BedrockConverse do
  @moduledoc """
  Wire protocol adapter for the AWS Bedrock Converse API format.

  Encodes Sycophant Request structs into the Bedrock Converse
  JSON format. The model is specified in the URL path, not the
  request body.
  """

  @behaviour Sycophant.WireProtocol

  alias Sycophant.Context
  alias Sycophant.Error.Provider.ResponseInvalid
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
              thinking_signature: nil,
              encrypted_thinking: nil,
              usage: nil,
              model: nil,
              current_block: nil,
              stop_reason: nil
  end

  @param_schema Zoi.map(
                  Map.take(ParamDefs.shared(), [
                    :temperature,
                    :max_tokens,
                    :top_p,
                    :stop,
                    :tool_choice,
                    :parallel_tool_calls,
                    :reasoning
                  ])
                )

  @reasoning_budgets %{
    minimal: 1024,
    low: 1024,
    medium: 4096,
    high: 16_384,
    xhigh: 32_768
  }

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
    max_tokens: "maxTokens",
    top_p: "topP",
    stop: "stopSequences"
  }

  @impl true
  def stream_transport, do: :event_stream

  @impl true
  def request_path(%Request{model: model, stream: stream}) do
    encoded_model = URI.encode(model, &(&1 != ?:))
    suffix = if stream, do: "converse-stream", else: "converse"
    "/model/#{encoded_model}/#{suffix}"
  end

  @impl true
  def encode_request(%Request{} = request) do
    {system_blocks, non_system} = split_system_messages(request.messages)

    with {:ok, messages} <- encode_messages(non_system) do
      build_payload(request, system_blocks, messages)
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
    {:ok, schema}
  end

  @impl true
  def decode_response(%{"output" => %{"message" => %{"content" => content}}} = body) do
    {text, tool_calls, reasoning} = process_content_blocks(content)

    response = %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      finish_reason: map_finish_reason(body["stopReason"]),
      usage: decode_usage(body["usage"]),
      model: nil,
      raw: body,
      context: %Context{messages: []}
    }

    {:ok, response}
  end

  def decode_response(body) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  @impl true
  def init_stream, do: %StreamState{}

  @impl true
  def decode_stream_chunk(state, %{event_type: "messageStart", payload: _}) do
    {:ok, state, []}
  end

  def decode_stream_chunk(state, %{
        event_type: "contentBlockStart",
        payload: %{
          "contentBlockIndex" => index,
          "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}
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
        event_type: "contentBlockStart",
        payload: %{"contentBlockIndex" => index}
      }) do
    {:ok, %{state | current_block: {:text, index}}, []}
  end

  def decode_stream_chunk(state, %{
        event_type: "contentBlockDelta",
        payload: %{"delta" => %{"reasoningContent" => %{"text" => text}}}
      }) do
    state = %{state | thinking: state.thinking <> text}
    {:ok, state, [%StreamChunk{type: :reasoning_delta, data: text}]}
  end

  def decode_stream_chunk(state, %{
        event_type: "contentBlockDelta",
        payload: %{"delta" => %{"reasoningContent" => %{"signature" => sig}}}
      }) do
    {:ok, %{state | thinking_signature: sig}, []}
  end

  def decode_stream_chunk(state, %{
        event_type: "contentBlockDelta",
        payload: %{"delta" => %{"text" => text}}
      }) do
    state = %{state | text: state.text <> text}
    {:ok, state, [%StreamChunk{type: :text_delta, data: text}]}
  end

  def decode_stream_chunk(state, %{
        event_type: "contentBlockDelta",
        payload: %{"contentBlockIndex" => index, "delta" => %{"toolUse" => %{"input" => json}}}
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

  def decode_stream_chunk(state, %{event_type: "contentBlockStop", payload: _}) do
    {:ok, %{state | current_block: nil}, []}
  end

  def decode_stream_chunk(state, %{event_type: "messageStop", payload: payload}) do
    {:ok, %{state | stop_reason: payload["stopReason"]}, []}
  end

  def decode_stream_chunk(state, %{
        event_type: "metadata",
        payload: %{"usage" => %{"inputTokens" => input, "outputTokens" => output}}
      }) do
    usage = %Usage{input_tokens: input, output_tokens: output}
    {:done, build_streamed_response(%{state | usage: usage})}
  end

  def decode_stream_chunk(state, _event), do: {:ok, state, []}

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
                else: [%Content.Thinking{text: thinking, signature: state.thinking_signature}]
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

  defp classify_content_block(%{"text" => text}, {texts, tcs, th, enc}),
    do: {[text | texts], tcs, th, enc}

  defp classify_content_block(
         %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}},
         {texts, tcs, th, enc}
       ),
       do: {texts, [%ToolCall{id: id, name: name, arguments: input} | tcs], th, enc}

  defp classify_content_block(
         %{"reasoningContent" => %{"reasoningText" => %{"text" => t} = rt}},
         {texts, tcs, th, enc}
       ),
       do: {texts, tcs, [%Content.Thinking{text: t, signature: rt["signature"]} | th], enc}

  defp classify_content_block(
         %{"reasoningContent" => %{"redactedContent" => data}},
         {texts, tcs, th, _enc}
       ),
       do: {texts, tcs, th, data}

  defp classify_content_block(_, acc), do: acc

  defp decode_usage(%{"inputTokens" => input, "outputTokens" => output}) do
    %Usage{input_tokens: input, output_tokens: output}
  end

  defp decode_usage(_), do: nil

  # --- Private: System Message Splitting ---

  defp split_system_messages(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &(&1.role == :system))

    blocks =
      system_msgs
      |> Enum.map(&system_content_block/1)
      |> Enum.reject(&is_nil/1)

    {blocks, rest}
  end

  defp system_content_block(%Message{content: content})
       when is_binary(content) and content != "" do
    %{"text" => content}
  end

  defp system_content_block(_), do: nil

  # --- Private: Message Encoding ---

  defp encode_messages(messages) do
    {:ok, Enum.map(messages, &encode_message/1)}
  end

  defp encode_message(%Message{role: :tool_result, tool_call_id: id, content: content}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "toolResult" => %{
            "toolUseId" => id,
            "content" => [%{"text" => to_string(content)}]
          }
        }
      ]
    }
  end

  defp encode_message(%Message{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    content_blocks = encode_assistant_content_blocks(content)

    tool_use_blocks =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => args}}
      end)

    %{"role" => "assistant", "content" => content_blocks ++ tool_use_blocks}
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => encode_role(role), "content" => encode_content(content)}
  end

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"

  defp encode_content(content) when is_binary(content), do: [%{"text" => content}]
  defp encode_content(nil), do: []

  defp encode_content(parts) when is_list(parts) do
    Enum.map(parts, &encode_content_part/1)
  end

  defp encode_content_part(%Content.Text{text: text}) do
    %{"text" => text}
  end

  defp encode_content_part(%Content.Thinking{text: text, signature: signature}) do
    block = %{"text" => text}
    block = if signature, do: Map.put(block, "signature", signature), else: block
    %{"reasoningContent" => %{"reasoningText" => block}}
  end

  defp encode_content_part(%Content.RedactedThinking{data: data}) do
    %{"reasoningContent" => %{"redactedContent" => data}}
  end

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    format = media_type_to_format(media_type)
    %{"image" => %{"format" => format, "source" => %{"bytes" => data}}}
  end

  defp encode_assistant_content_blocks(nil), do: []
  defp encode_assistant_content_blocks(""), do: []

  defp encode_assistant_content_blocks(text) when is_binary(text),
    do: [%{"text" => text}]

  defp encode_assistant_content_blocks(parts) when is_list(parts),
    do: Enum.map(parts, &encode_content_part/1)

  defp media_type_to_format("image/" <> format), do: format
  defp media_type_to_format(format), do: format

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    {:ok,
     %{
       "toolSpec" => %{
         "name" => name,
         "description" => description,
         "inputSchema" => %{"json" => parameters}
       }
     }}
  end

  # --- Private: Param Translation ---

  defp translate_params(params) when is_map(params) do
    Enum.reduce(@param_map, %{}, fn {canonical, wire_key}, acc ->
      case Map.get(params, canonical) do
        nil -> acc
        value -> Map.put(acc, wire_key, value)
      end
    end)
  end

  # --- Private: Tool Choice ---

  defp maybe_put_tool_choice(tool_config, %{tool_choice: :auto}) do
    Map.put(tool_config, "toolChoice", %{"auto" => %{}})
  end

  defp maybe_put_tool_choice(tool_config, %{tool_choice: :any}) do
    Map.put(tool_config, "toolChoice", %{"any" => %{}})
  end

  defp maybe_put_tool_choice(tool_config, %{tool_choice: {:tool, name}}) do
    Map.put(tool_config, "toolChoice", %{"tool" => %{"name" => name}})
  end

  defp maybe_put_tool_choice(tool_config, _), do: tool_config

  # --- Private: Payload Assembly ---

  defp build_payload(request, system_blocks, messages) do
    base = %{"messages" => messages}
    base = if system_blocks != [], do: Map.put(base, "system", system_blocks), else: base

    with {:ok, payload} <- maybe_put_tools(base, request.tools, request.params),
         {:ok, payload} <- maybe_put_response_format(payload, request.response_schema) do
      inference_config = translate_params(request.params)

      payload =
        if map_size(inference_config) > 0 do
          Map.put(payload, "inferenceConfig", inference_config)
        else
          payload
        end

      payload = maybe_put_thinking(payload, request.params)

      {:ok, payload}
    end
  end

  defp maybe_put_response_format(payload, nil), do: {:ok, payload}

  defp maybe_put_response_format(payload, schema) do
    {:ok, json_schema} = encode_response_schema(schema)
    strict_schema = set_strict_additional_properties(json_schema)

    output_config = %{
      "textFormat" => %{
        "type" => "json_schema",
        "structure" => %{
          "jsonSchema" => %{
            "schema" => JSON.encode!(strict_schema),
            "name" => "response_schema"
          }
        }
      }
    }

    {:ok, Map.put(payload, "outputConfig", output_config)}
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

  defp maybe_put_tools(payload, [], _params), do: {:ok, payload}

  defp maybe_put_tools(payload, tools, params) do
    {:ok, encoded} = encode_tools(tools)
    tool_config = %{"tools" => encoded}
    tool_config = maybe_put_tool_choice(tool_config, params)
    {:ok, Map.put(payload, "toolConfig", tool_config)}
  end

  # --- Private: Thinking ---

  defp maybe_put_thinking(payload, %{reasoning: :none}) do
    Map.put(payload, "additionalModelRequestFields", %{
      "thinking" => %{"type" => "disabled"}
    })
  end

  defp maybe_put_thinking(payload, %{reasoning: level})
       when is_map_key(@reasoning_budgets, level) do
    budget = Map.fetch!(@reasoning_budgets, level)

    Map.put(payload, "additionalModelRequestFields", %{
      "thinking" => %{"type" => "enabled", "budget_tokens" => budget}
    })
  end

  defp maybe_put_thinking(payload, _), do: payload

  # --- Finish Reason Mapping ---

  defp map_finish_reason("end_turn"), do: :stop
  defp map_finish_reason("tool_use"), do: :tool_use
  defp map_finish_reason("max_tokens"), do: :max_tokens
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
