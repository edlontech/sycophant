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
    defstruct text: "", tool_calls: %{}, thinking: "", usage: nil, model: nil
  end

  @param_schema Zoi.map(
                  Map.merge(
                    Map.take(ParamDefs.shared(), [
                      :temperature,
                      :max_tokens,
                      :top_p,
                      :top_k,
                      :stop,
                      :reasoning_effort,
                      :reasoning_budget,
                      :reasoning_summary,
                      :tool_choice,
                      :parallel_tool_calls
                    ]),
                    %{
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
                        |> Zoi.min(0)
                        |> Zoi.max(20)
                        |> Zoi.optional()
                    }
                  )
                )

  @type t :: unquote(Zoi.type_spec(@param_schema))

  @impl true
  @doc """
  #{Zoi.description(@param_schema)}

  Options:

  #{Zoi.describe(@param_schema)}
  """
  def param_schema, do: @param_schema

  @impl true
  def stream_transport, do: :sse

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
    {:ok,
     Enum.map(tools, fn tool ->
       {:ok, encoded} = encode_tool(tool)
       encoded
     end)}
  end

  @impl true
  def encode_response_schema(schema) do
    {:ok, strip_additional_properties(schema)}
  end

  @impl true
  def decode_response(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]} = body) do
    {text, tool_calls, reasoning} = process_parts(parts)

    response = %Response{
      text: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      finish_reason:
        map_finish_reason(get_in(body, ["candidates", Access.at(0), "finishReason"])),
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
              else: %Reasoning{content: [%Content.Thinking{text: state.thinking}]}
            ),
          finish_reason: map_finish_reason(reason),
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
      Enum.reduce(parts, {[], [], [], 0}, &classify_part/2)

    text =
      case Enum.reverse(texts) do
        [] -> nil
        parts -> Enum.join(parts, "")
      end

    reasoning =
      case Enum.reverse(reasonings) do
        [] -> nil
        parts -> %Reasoning{content: parts}
      end

    {text, Enum.reverse(tool_calls), reasoning}
  end

  defp classify_part(%{"text" => text, "thought" => true}, {texts, tcs, reasons, idx}),
    do: {texts, tcs, [%Content.Thinking{text: text} | reasons], idx}

  defp classify_part(%{"text" => text}, {texts, tcs, reasons, idx}),
    do: {[text | texts], tcs, reasons, idx}

  defp classify_part(
         %{"functionCall" => %{"name" => name, "args" => args}} = part,
         {texts, tcs, reasons, idx}
       ) do
    metadata =
      case part["thoughtSignature"] do
        nil -> %{}
        sig -> %{thought_signature: sig}
      end

    tc = %ToolCall{id: "gemini_call_#{idx}", name: name, arguments: args, metadata: metadata}
    {texts, [tc | tcs], reasons, idx + 1}
  end

  defp classify_part(_, acc), do: acc

  defp decode_usage(%{"promptTokenCount" => input, "candidatesTokenCount" => output} = meta) do
    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: meta["cachedContentTokenCount"],
      reasoning_tokens: meta["thoughtsTokenCount"]
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

        %{"functionCall" => %{"name" => name, "args" => args}} = fc_part ->
          idx = map_size(st.tool_calls)
          id = "gemini_call_#{idx}"
          sig = fc_part["thoughtSignature"]

          tc_data = %{id: id, name: name, arguments: args, thought_signature: sig}
          st = %{st | tool_calls: Map.put(st.tool_calls, idx, tc_data)}

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
        metadata =
          case tc[:thought_signature] do
            nil -> %{}
            sig -> %{thought_signature: sig}
          end

        %ToolCall{id: tc.id, name: tc.name, arguments: tc.arguments, metadata: metadata}
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
        nil ->
          []

        "" ->
          []

        text when is_binary(text) ->
          [%{"text" => text}]

        parts when is_list(parts) ->
          parts |> Enum.map(&encode_content_part/1) |> Enum.reject(&is_nil/1)
      end

    tool_parts = Enum.map(tool_calls, &encode_function_call_part/1)

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
    parts |> Enum.map(&encode_content_part/1) |> Enum.reject(&is_nil/1)
  end

  defp encode_content_part(%Content.Text{text: text}), do: %{"text" => text}

  defp encode_content_part(%Content.Thinking{text: text}),
    do: %{"text" => text, "thought" => true}

  defp encode_content_part(%Content.RedactedThinking{}), do: nil

  defp encode_content_part(%Content.Image{url: url}) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url, "mimeType" => "image/*"}}
  end

  defp encode_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_function_call_part(%ToolCall{name: name, arguments: args, metadata: metadata}) do
    part = %{"functionCall" => %{"name" => name, "args" => args}}

    case metadata[:thought_signature] do
      nil -> part
      sig -> Map.put(part, "thoughtSignature", sig)
    end
  end

  # --- Private: Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    {:ok,
     %{
       "name" => name,
       "description" => description,
       "parameters" => strip_additional_properties(parameters)
     }}
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
      payload = maybe_put_tool_choice(payload, request.params)

      {:ok, payload}
    end
  end

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    {:ok, encoded} = encode_tools(tools)
    {:ok, Map.put(payload, "tools", [%{"functionDeclarations" => encoded}])}
  end

  defp maybe_put_tool_choice(payload, %{tool_choice: :auto}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "AUTO"}})

  defp maybe_put_tool_choice(payload, %{tool_choice: :none}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "NONE"}})

  defp maybe_put_tool_choice(payload, %{tool_choice: :any}),
    do: Map.put(payload, "toolConfig", %{"functionCallingConfig" => %{"mode" => "ANY"}})

  defp maybe_put_tool_choice(payload, %{tool_choice: {:tool, name}}) do
    Map.put(payload, "toolConfig", %{
      "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => [name]}
    })
  end

  defp maybe_put_tool_choice(payload, _), do: payload

  defp maybe_put_generation_config(payload, request) do
    with {:ok, config} <-
           build_generation_config(request.params, request.response_schema, request.model) do
      if config == %{},
        do: {:ok, payload},
        else: {:ok, Map.put(payload, "generationConfig", config)}
    end
  end

  defp build_generation_config(params, response_schema, _model)
       when map_size(params) == 0 and is_nil(response_schema),
       do: {:ok, %{}}

  defp build_generation_config(params, response_schema, model) do
    config = translate_params(params)
    config = maybe_put_thinking_config(config, params, model)
    maybe_put_response_schema_config(config, response_schema)
  end

  @gemini_param_map %{
    temperature: "temperature",
    top_p: "topP",
    top_k: "topK",
    stop: "stopSequences",
    max_tokens: "maxOutputTokens",
    seed: "seed",
    frequency_penalty: "frequencyPenalty",
    presence_penalty: "presencePenalty",
    logprobs: "responseLogprobs",
    top_logprobs: "logprobs"
  }

  defp translate_params(params) when is_map(params) do
    Enum.reduce(@gemini_param_map, %{}, fn {canonical, wire_key}, acc ->
      case Map.get(params, canonical) do
        nil -> acc
        value -> Map.put(acc, wire_key, value)
      end
    end)
  end

  @thinking_levels %{
    minimal: "MINIMAL",
    low: "LOW",
    medium: "MEDIUM",
    high: "HIGH",
    xhigh: "HIGH"
  }

  @thinking_budgets %{
    minimal: 1024,
    low: 1024,
    medium: 4096,
    high: 16_384,
    xhigh: 32_768
  }

  # Models before gemini-3 use thinkingBudget; gemini-3+ use thinkingLevel
  @legacy_thinking_prefixes ~w(gemini-1 gemini-2)

  defp maybe_put_thinking_config(config, params, model) do
    thinking_config =
      params
      |> build_thinking_level(model)
      |> maybe_include_thoughts(params)

    if thinking_config == %{},
      do: config,
      else: Map.put(config, "thinkingConfig", thinking_config)
  end

  defp build_thinking_level(%{reasoning_budget: budget}, _model)
       when is_integer(budget),
       do: %{"thinkingBudget" => budget}

  defp build_thinking_level(%{reasoning_effort: :none}, _model),
    do: %{"thinkingBudget" => 0}

  defp build_thinking_level(%{reasoning_effort: level}, model)
       when is_map_key(@thinking_levels, level) do
    if legacy_thinking_model?(model) do
      %{"thinkingBudget" => Map.fetch!(@thinking_budgets, level)}
    else
      %{"thinkingLevel" => Map.fetch!(@thinking_levels, level)}
    end
  end

  defp build_thinking_level(_, _model), do: %{}

  defp legacy_thinking_model?(model) do
    Enum.any?(@legacy_thinking_prefixes, &String.starts_with?(model, &1))
  end

  defp maybe_include_thoughts(thinking_config, %{reasoning_summary: value})
       when value not in [nil, :none] do
    Map.put(thinking_config, "includeThoughts", true)
  end

  defp maybe_include_thoughts(thinking_config, _), do: thinking_config

  defp maybe_put_response_schema_config(config, nil), do: {:ok, config}

  defp maybe_put_response_schema_config(config, schema) do
    {:ok, json_schema} = encode_response_schema(schema)

    {:ok,
     config
     |> Map.put("responseMimeType", "application/json")
     |> Map.put("responseSchema", json_schema)}
  end

  defp strip_additional_properties(map) when is_map(map) do
    map
    |> Map.delete("additionalProperties")
    |> Map.new(fn {k, v} -> {k, strip_additional_properties(v)} end)
  end

  defp strip_additional_properties(list) when is_list(list) do
    Enum.map(list, &strip_additional_properties/1)
  end

  defp strip_additional_properties(value), do: value

  # --- Finish Reason Mapping ---

  defp map_finish_reason("STOP"), do: :stop
  defp map_finish_reason("MAX_TOKENS"), do: :max_tokens
  defp map_finish_reason("SAFETY"), do: :content_filter
  defp map_finish_reason("SPII"), do: :content_filter
  defp map_finish_reason("IMAGE_SAFETY"), do: :content_filter
  defp map_finish_reason("RECITATION"), do: :recitation
  defp map_finish_reason("MALFORMED_FUNCTION_CALL"), do: :error
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
