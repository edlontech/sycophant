defmodule Sycophant.WireProtocol.GoogleGemini do
  @moduledoc """
  Wire protocol adapter for the Google Gemini API format.

  Encodes Sycophant Request structs into the Gemini
  JSON format and decodes responses back into Response structs.
  """

  @behaviour Sycophant.WireProtocol

  alias Sycophant.Context
  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Params
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
    defstruct text: "", tool_calls: %{}, thinking: "", usage: nil, model: nil
  end

  @impl true
  def request_path(%Request{model: model, stream: stream}) do
    base = "/models/#{model}"
    if stream, do: "#{base}:streamGenerateContent?alt=sse", else: "#{base}:generateContent"
  end

  @impl true
  def encode_request(%Request{} = request) do
    {system_text, non_system} = split_system_messages(request.messages)

    with {:ok, contents} <- encode_contents(non_system) do
      build_payload(request, system_text, contents)
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
    with {:ok, json_schema} <- JsonSchema.to_json_schema(schema) do
      {:ok, strip_additional_properties(json_schema)}
    end
  end

  @impl true
  def decode_response(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]} = body) do
    {text, tool_calls, reasoning} = process_parts(parts)

    response = %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      usage: decode_usage(body["usageMetadata"]),
      model: body["modelVersion"],
      raw: body,
      context: %Context{messages: []}
    }

    {:ok, response}
  end

  def decode_response(%{"error" => %{"code" => code} = error}) do
    {:error, decode_api_error(code, error)}
  end

  def decode_response(body) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  @impl true
  def init_stream, do: %StreamState{}

  @impl true
  def decode_stream_chunk(state, %{data: %{"candidates" => [candidate | _]} = body}) do
    state = maybe_capture_model(state, body)
    state = maybe_capture_usage(state, body)
    {state, chunks} = process_streaming_candidate(state, candidate)

    case candidate["finishReason"] do
      reason when reason in ["STOP", "MAX_TOKENS", "SAFETY"] ->
        {_text, final_tool_calls, _} = finalize_stream_parts(state)

        response = %Response{
          text: if(state.text == "", do: nil, else: state.text),
          tool_calls: final_tool_calls,
          reasoning:
            if(state.thinking == "",
              do: nil,
              else: %Reasoning{summary: state.thinking}
            ),
          usage: state.usage,
          model: state.model,
          context: %Context{messages: []}
        }

        {:done, response, chunks}

      _ ->
        {:ok, state, chunks}
    end
  end

  def decode_stream_chunk(state, _event), do: {:ok, state, []}

  # --- Private: Response Decoding ---

  defp process_parts(parts) do
    {texts, tool_calls, reasonings, _tc_index} =
      Enum.reduce(parts, {[], [], [], 0}, fn part, {texts, tcs, reasons, idx} ->
        case part do
          %{"text" => text, "thought" => true} ->
            {texts, tcs, [text | reasons], idx}

          %{"text" => text} ->
            {[text | texts], tcs, reasons, idx}

          %{"functionCall" => %{"name" => name, "args" => args}} ->
            tc = %ToolCall{id: "gemini_call_#{idx}", name: name, arguments: args}
            {texts, [tc | tcs], reasons, idx + 1}

          _ ->
            {texts, tcs, reasons, idx}
        end
      end)

    text =
      case Enum.reverse(texts) do
        [] -> nil
        parts -> Enum.join(parts, "")
      end

    reasoning =
      case Enum.reverse(reasonings) do
        [] -> nil
        parts -> %Reasoning{summary: Enum.join(parts, "")}
      end

    {text, Enum.reverse(tool_calls), reasoning}
  end

  defp decode_usage(%{"promptTokenCount" => input, "candidatesTokenCount" => output} = meta) do
    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: meta["cachedContentTokenCount"]
    }
  end

  defp decode_usage(_), do: nil

  defp decode_api_error(429, _error), do: RateLimited.exception([])

  defp decode_api_error(code, error) when code in [500, 503] do
    ServerError.exception(status: code, body: error["message"])
  end

  defp decode_api_error(_code, error) do
    ResponseInvalid.exception(errors: [error["message"]])
  end

  # --- Private: Streaming ---

  defp maybe_capture_model(state, %{"modelVersion" => model}), do: %{state | model: model}
  defp maybe_capture_model(state, _), do: state

  defp maybe_capture_usage(state, %{"usageMetadata" => meta}) do
    %{state | usage: decode_usage(meta)}
  end

  defp maybe_capture_usage(state, _), do: state

  defp process_streaming_candidate(state, candidate) do
    parts = get_in(candidate, ["content", "parts"]) || []

    Enum.reduce(parts, {state, []}, fn part, {st, chunks} ->
      case part do
        %{"text" => text, "thought" => true} ->
          st = %{st | thinking: st.thinking <> text}
          {st, chunks ++ [%StreamChunk{type: :reasoning_delta, data: text}]}

        %{"text" => text} ->
          st = %{st | text: st.text <> text}
          {st, chunks ++ [%StreamChunk{type: :text_delta, data: text}]}

        %{"functionCall" => %{"name" => name, "args" => args}} ->
          idx = map_size(st.tool_calls)
          id = "gemini_call_#{idx}"

          st = %{
            st
            | tool_calls: Map.put(st.tool_calls, idx, %{id: id, name: name, arguments: args})
          }

          chunk = %StreamChunk{
            type: :tool_call_delta,
            data: %{id: id, name: name, arguments_delta: JSON.encode!(args)},
            index: idx
          }

          {st, chunks ++ [chunk]}

        _ ->
          {st, chunks}
      end
    end)
  end

  defp finalize_stream_parts(state) do
    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, tc} ->
        %ToolCall{id: tc.id, name: tc.name, arguments: tc.arguments}
      end)

    text = if state.text == "", do: nil, else: state.text
    {text, tool_calls, nil}
  end

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

  # --- Private: Content Encoding ---

  defp encode_contents(messages) do
    {:ok, Enum.map(messages, &encode_message/1)}
  end

  defp encode_message(%Message{role: :tool_result, content: content} = msg) do
    %{
      "role" => "user",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => find_tool_name(msg),
            "response" => %{"content" => to_string(content)}
          }
        }
      ]
    }
  end

  defp encode_message(%Message{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    text_parts =
      case content do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"text" => text}]
      end

    tool_parts =
      Enum.map(tool_calls, fn %ToolCall{name: name, arguments: args} ->
        %{"functionCall" => %{"name" => name, "args" => args}}
      end)

    %{"role" => "model", "parts" => text_parts ++ tool_parts}
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => encode_role(role), "parts" => encode_parts(content)}
  end

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "model"

  defp encode_parts(content) when is_binary(content), do: [%{"text" => content}]
  defp encode_parts(nil), do: []

  defp encode_parts(parts) when is_list(parts) do
    Enum.map(parts, &encode_content_part/1)
  end

  defp encode_content_part(%Content.Text{text: text}), do: %{"text" => text}

  defp encode_content_part(%Content.Image{url: url}) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url, "mimeType" => "image/*"}}
  end

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(parameters) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "parameters" => strip_additional_properties(json_schema)
       }}
    end
  end

  # --- Private: Tool Result Helper ---

  defp find_tool_name(%Message{metadata: %{tool_name: name}})
       when is_binary(name),
       do: name

  defp find_tool_name(%Message{tool_call_id: id}) when is_binary(id), do: id
  defp find_tool_name(_), do: "unknown"

  # --- Private: Payload Assembly ---

  defp build_payload(request, system_text, contents) do
    base = %{"contents" => contents}

    base =
      if system_text,
        do: Map.put(base, "system_instruction", %{"parts" => [%{"text" => system_text}]}),
        else: base

    with {:ok, payload} <- maybe_put_tools(base, request.tools),
         {:ok, payload} <- maybe_put_generation_config(payload, request) do
      payload =
        payload
        |> maybe_put_tool_choice(request.params)
        |> Map.merge(provider_params(request.provider_params))

      {:ok, payload}
    end
  end

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    case encode_tools(tools) do
      {:ok, encoded} ->
        {:ok, Map.put(payload, "tools", [%{"functionDeclarations" => encoded}])}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_put_tool_choice(payload, nil), do: payload
  defp maybe_put_tool_choice(payload, %Params{tool_choice: nil}), do: payload

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :auto}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "AUTO"}})

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :none}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "NONE"}})

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :any}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "ANY"}})

  defp maybe_put_tool_choice(payload, %Params{tool_choice: {:tool, name}}) do
    Map.put(payload, "toolConfig", %{
      "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => [name]}
    })
  end

  defp maybe_put_generation_config(payload, request) do
    with {:ok, config} <- build_generation_config(request.params, request.response_schema) do
      if config == %{},
        do: {:ok, payload},
        else: {:ok, Map.put(payload, "generationConfig", config)}
    end
  end

  defp build_generation_config(nil, nil), do: {:ok, %{}}

  defp build_generation_config(params, response_schema) do
    config = translate_params(params)
    config = maybe_put_thinking_config(config, params)

    case maybe_put_response_schema_config(config, response_schema) do
      {:ok, config} -> {:ok, config}
      {:error, _} = err -> err
    end
  end

  defp translate_params(nil), do: %{}

  defp translate_params(%Params{} = params) do
    %{}
    |> put_if_set(:temperature, params.temperature, "temperature")
    |> put_if_set(:top_p, params.top_p, "topP")
    |> put_if_set(:top_k, params.top_k, "topK")
    |> put_if_set(:stop, params.stop, "stopSequences")
    |> put_if_set(:max_tokens, params.max_tokens, "maxOutputTokens")
  end

  defp put_if_set(map, _key, nil, _target), do: map
  defp put_if_set(map, _key, value, target), do: Map.put(map, target, value)

  @thinking_levels %{low: "LOW", medium: "MEDIUM", high: "HIGH"}

  defp maybe_put_thinking_config(config, nil), do: config

  defp maybe_put_thinking_config(config, %Params{reasoning: level})
       when is_atom(level) and not is_nil(level) do
    Map.put(config, "thinkingConfig", %{"thinkingLevel" => Map.fetch!(@thinking_levels, level)})
  end

  defp maybe_put_thinking_config(config, _), do: config

  defp maybe_put_response_schema_config(config, nil), do: {:ok, config}

  defp maybe_put_response_schema_config(config, schema) do
    case encode_response_schema(schema) do
      {:ok, json_schema} ->
        {:ok,
         config
         |> Map.put("responseMimeType", "application/json")
         |> Map.put("responseSchema", json_schema)}

      {:error, _} = err ->
        err
    end
  end

  defp provider_params(nil), do: %{}
  defp provider_params(params), do: params

  defp strip_additional_properties(map) when is_map(map) do
    map
    |> Map.delete("additionalProperties")
    |> Map.new(fn {k, v} -> {k, strip_additional_properties(v)} end)
  end

  defp strip_additional_properties(list) when is_list(list) do
    Enum.map(list, &strip_additional_properties/1)
  end

  defp strip_additional_properties(value), do: value
end
