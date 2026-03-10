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
  alias Sycophant.Params
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
              usage: nil,
              model: nil,
              current_block: nil,
              stop_reason: nil
  end

  @param_map %{
    temperature: "temperature",
    max_tokens: "maxTokens",
    top_p: "topP",
    stop: "stopSequences"
  }

  @supported_params Map.keys(@param_map)

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

  @impl true
  def encode_response_schema(schema) do
    JsonSchema.to_json_schema(schema)
  end

  @impl true
  def decode_response(%{"output" => %{"message" => %{"content" => content}}} = body) do
    {text, tool_calls} = process_content_blocks(content)

    response = %Response{
      text: text,
      tool_calls: tool_calls,
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

    %Response{
      text: text,
      tool_calls: tool_calls,
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
    Enum.reduce(content, {[], []}, fn block, {texts, tcs} ->
      case block do
        %{"text" => text} ->
          {[text | texts], tcs}

        %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}} ->
          tc = %ToolCall{id: id, name: name, arguments: input}
          {texts, [tc | tcs]}

        _ ->
          {texts, tcs}
      end
    end)
    |> then(fn {texts, tcs} ->
      text =
        case Enum.reverse(texts) do
          [] -> nil
          parts -> Enum.join(parts, "")
        end

      {text, Enum.reverse(tcs)}
    end)
  end

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
    text_blocks =
      case content do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"text" => text}]
      end

    tool_use_blocks =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => args}}
      end)

    %{"role" => "assistant", "content" => text_blocks ++ tool_use_blocks}
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

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    format = media_type_to_format(media_type)
    %{"image" => %{"format" => format, "source" => %{"bytes" => data}}}
  end

  defp media_type_to_format("image/" <> format), do: format
  defp media_type_to_format(format), do: format

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(parameters) do
      {:ok,
       %{
         "toolSpec" => %{
           "name" => name,
           "description" => description,
           "inputSchema" => %{"json" => json_schema}
         }
       }}
    end
  end

  # --- Private: Param Translation ---

  defp translate_params(nil), do: %{}

  defp translate_params(%Params{} = params) do
    params
    |> Map.from_struct()
    |> Enum.filter(fn {k, v} -> not is_nil(v) and k in @supported_params end)
    |> Map.new(&translate_param/1)
  end

  defp translate_param({key, value}), do: {Map.fetch!(@param_map, key), value}

  # --- Private: Tool Choice ---

  defp maybe_put_tool_choice(tool_config, nil), do: tool_config
  defp maybe_put_tool_choice(tool_config, %Params{tool_choice: nil}), do: tool_config

  defp maybe_put_tool_choice(tool_config, %Params{tool_choice: :auto}) do
    Map.put(tool_config, "toolChoice", %{"auto" => %{}})
  end

  defp maybe_put_tool_choice(tool_config, %Params{tool_choice: :any}) do
    Map.put(tool_config, "toolChoice", %{"any" => %{}})
  end

  defp maybe_put_tool_choice(tool_config, %Params{tool_choice: {:tool, name}}) do
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

      payload = Map.merge(payload, request.provider_params || %{})

      {:ok, payload}
    end
  end

  defp maybe_put_response_format(payload, nil), do: {:ok, payload}

  defp maybe_put_response_format(payload, schema) do
    case encode_response_schema(schema) do
      {:ok, json_schema} ->
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

      {:error, _} = err ->
        err
    end
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
    case encode_tools(tools) do
      {:ok, encoded} ->
        tool_config = %{"tools" => encoded}
        tool_config = maybe_put_tool_choice(tool_config, params)
        {:ok, Map.put(payload, "toolConfig", tool_config)}

      {:error, _} = err ->
        err
    end
  end

  # --- Finish Reason Mapping ---

  defp map_finish_reason("end_turn"), do: :stop
  defp map_finish_reason("tool_use"), do: :tool_use
  defp map_finish_reason("max_tokens"), do: :max_tokens
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
