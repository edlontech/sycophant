defmodule Sycophant.WireProtocol.OpenAIResponses do
  @moduledoc """
  Wire protocol adapter for the OpenAI Responses API format.

  Encodes Sycophant Request structs into the `POST /v1/responses`
  JSON format and decodes responses back into Response structs.
  Uses items instead of messages, flat tool definitions, and
  extracts system messages into the `instructions` field.
  """

  @behaviour Sycophant.WireProtocol

  @impl true
  def request_path(_request), do: "/responses"

  @impl true
  def stream_transport, do: :sse

  alias Sycophant.Context
  alias Sycophant.Error.Provider.ContentFiltered
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

  @param_schema Zoi.map(
                  Map.merge(ParamDefs.shared(), %{
                    cache_key:
                      Zoi.string(description: "Cache key for prompt caching")
                      |> Zoi.optional(),
                    cache_retention:
                      Zoi.enum(["in-memory", "24h"],
                        description: "Cache retention policy"
                      )
                      |> Zoi.optional(),
                    safety_identifier:
                      Zoi.string(description: "Safety identifier for content filtering")
                      |> Zoi.optional(),
                    store:
                      Zoi.boolean(
                        description: "Whether to store the response for later retrieval"
                      )
                      |> Zoi.optional(),
                    truncation:
                      Zoi.enum([:auto, :disabled],
                        description: "Context window overflow handling"
                      )
                      |> Zoi.optional(),
                    include:
                      Zoi.list(Zoi.string(),
                        description: "Additional output data to include in the response"
                      )
                      |> Zoi.optional(),
                    top_logprobs:
                      Zoi.integer(
                        description: "Number of most likely tokens to return per position"
                      )
                      |> Zoi.min(0)
                      |> Zoi.max(20)
                      |> Zoi.optional(),
                    max_tool_calls:
                      Zoi.integer(description: "Maximum number of tool calls per response")
                      |> Zoi.positive()
                      |> Zoi.optional(),
                    metadata:
                      Zoi.any(description: "Key-value metadata to attach to the response")
                      |> Zoi.optional(),
                    stream_options:
                      Zoi.any(description: "Options for streaming responses")
                      |> Zoi.optional(),
                    context_management:
                      Zoi.any(description: "Context management configuration")
                      |> Zoi.optional(),
                    verbosity:
                      Zoi.enum([:low, :medium, :high],
                        description: "Response verbosity level"
                      )
                      |> Zoi.optional(),
                    previous_response_id:
                      Zoi.string(description: "ID of a previous response to chain from")
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
    max_tokens: "max_output_tokens",
    top_p: "top_p",
    parallel_tool_calls: "parallel_tool_calls",
    service_tier: "service_tier",
    cache_key: "prompt_cache_key",
    cache_retention: "prompt_cache_retention",
    safety_identifier: "safety_identifier",
    store: "store",
    include: "include",
    top_logprobs: "top_logprobs",
    max_tool_calls: "max_tool_calls",
    metadata: "metadata",
    previous_response_id: "previous_response_id"
  }

  @impl true
  def encode_request(%Request{} = request) do
    {instructions, input_messages} = split_messages(request.messages)

    with {:ok, input} <- encode_input(input_messages) do
      build_payload(request, instructions, input)
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
       "name" => "response",
       "strict" => true,
       "schema" => set_strict_additional_properties(schema)
     }}
  end

  @impl true
  def decode_response(%{"status" => "failed", "error" => error}) do
    {:error, decode_api_error(error)}
  end

  def decode_response(%{"status" => "incomplete", "incomplete_details" => details}) do
    reason = if details, do: details["reason"], else: "unknown"
    {:error, ResponseInvalid.exception(errors: ["Response incomplete: #{reason}"])}
  end

  def decode_response(%{"output" => output} = body) when is_list(output) do
    with {:ok, text, tool_calls, reasoning} <- process_output_items(output) do
      response = %Response{
        text: text,
        tool_calls: tool_calls,
        reasoning: reasoning,
        finish_reason: map_finish_reason(body["status"]),
        usage: decode_usage(body["usage"]),
        model: body["model"],
        raw: body,
        context: %Context{messages: []},
        metadata: decode_metadata(body)
      }

      {:ok, response}
    end
  end

  def decode_response(body) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  @impl true
  def init_stream, do: nil

  @impl true
  def decode_stream_chunk(_state, %{
        event: "response.output_text.delta",
        data: %{"delta" => delta}
      }) do
    {:ok, nil, [%StreamChunk{type: :text_delta, data: delta}]}
  end

  def decode_stream_chunk(_state, %{event: "response.function_call_arguments.delta", data: data}) do
    chunk = %StreamChunk{
      type: :tool_call_delta,
      data: %{id: data["item_id"], name: nil, arguments_delta: data["delta"]},
      index: data["output_index"]
    }

    {:ok, nil, [chunk]}
  end

  def decode_stream_chunk(_state, %{event: "response.reasoning_text.delta", data: data}) do
    {:ok, nil, [%StreamChunk{type: :reasoning_delta, data: data["delta"]}]}
  end

  def decode_stream_chunk(_state, %{event: "response.reasoning_summary_text.delta", data: data}) do
    {:ok, nil, [%StreamChunk{type: :reasoning_delta, data: data["delta"]}]}
  end

  def decode_stream_chunk(_state, %{event: "response.completed", data: %{"response" => response}}) do
    with {:ok, response} <- decode_response(response) do
      {:done, response}
    end
  end

  def decode_stream_chunk(state, %{data: %{"type" => type}} = event)
      when not is_map_key(event, :event) do
    decode_stream_chunk(state, Map.put(event, :event, type))
  end

  def decode_stream_chunk(state, _event) do
    {:ok, state, []}
  end

  # --- Response Decoding Helpers ---

  defp process_output_items(items) do
    Enum.reduce_while(items, {:ok, [], [], nil}, fn item, {:ok, texts, tcs, reasoning} ->
      case process_output_item(item) do
        {:text, t} -> {:cont, {:ok, [t | texts], tcs, reasoning}}
        {:tool_call, tc} -> {:cont, {:ok, texts, [tc | tcs], reasoning}}
        {:reasoning, r} -> {:cont, {:ok, texts, tcs, r}}
        :skip -> {:cont, {:ok, texts, tcs, reasoning}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, [], tcs, reasoning} ->
        {:ok, nil, Enum.reverse(tcs), reasoning}

      {:ok, texts, tcs, reasoning} ->
        text = texts |> Enum.reverse() |> Enum.join("")
        {:ok, text, Enum.reverse(tcs), reasoning}

      {:error, _} = err ->
        err
    end)
  end

  defp process_output_item(%{"type" => "message", "content" => content}) when is_list(content) do
    Enum.reduce_while(content, {:texts, []}, fn
      %{"type" => "output_text", "text" => text}, {:texts, acc} ->
        {:cont, {:texts, [text | acc]}}

      %{"type" => "refusal", "refusal" => reason}, _acc ->
        {:halt, {:error, ContentFiltered.exception(reason: reason)}}

      _other, acc ->
        {:cont, acc}
    end)
    |> case do
      {:texts, []} -> :skip
      {:texts, parts} -> {:text, parts |> Enum.reverse() |> Enum.join("")}
      {:error, _} = err -> err
    end
  end

  defp process_output_item(%{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => args
       })
       when is_binary(args) do
    case JSON.decode(args) do
      {:ok, decoded} ->
        {:tool_call, %ToolCall{id: id, name: name, arguments: decoded}}

      {:error, _} ->
        {:error,
         ResponseInvalid.exception(
           errors: ["Failed to decode tool call arguments for #{name}: #{args}"]
         )}
    end
  end

  defp process_output_item(%{"type" => "function_call"} = tc) do
    {:error, ResponseInvalid.exception(errors: ["Malformed function_call: #{inspect(tc)}"])}
  end

  defp process_output_item(%{"type" => "reasoning"} = item) do
    content_text = extract_reasoning_text(item["content"])
    summary_text = extract_summary_text(item["summary"])
    encrypted = item["encrypted_content"]

    thinking =
      if content_text || summary_text do
        %Content.Thinking{text: content_text, summary: summary_text}
      end

    content = if thinking, do: [thinking], else: []

    if content != [] || encrypted do
      {:reasoning, %Reasoning{id: item["id"], content: content, encrypted_content: encrypted}}
    else
      :skip
    end
  end

  defp process_output_item(_other) do
    :skip
  end

  defp extract_reasoning_text(nil), do: nil

  defp extract_reasoning_text(items) when is_list(items) do
    text =
      items
      |> Enum.filter(&(&1["type"] == "reasoning_text"))
      |> Enum.map_join("", & &1["text"])

    if text == "", do: nil, else: text
  end

  defp extract_summary_text(nil), do: nil

  defp extract_summary_text(items) when is_list(items) do
    text =
      items
      |> Enum.filter(&(&1["type"] == "summary_text"))
      |> Enum.map_join("", & &1["text"])

    if text == "", do: nil, else: text
  end

  defp decode_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"])
    reasoning = get_in(usage, ["output_tokens_details", "reasoning_tokens"])

    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached,
      reasoning_tokens: reasoning
    }
  end

  defp decode_usage(_), do: nil

  defp decode_metadata(%{"id" => id}) when is_binary(id) do
    %{openai_responses: %{id: id}}
  end

  defp decode_metadata(_), do: %{}

  defp decode_api_error(%{"code" => "server_error", "message" => msg}) do
    ServerError.exception(body: msg)
  end

  defp decode_api_error(%{"code" => "rate_limit_exceeded"}) do
    RateLimited.exception([])
  end

  defp decode_api_error(%{"code" => code, "message" => msg}) do
    ResponseInvalid.exception(errors: ["#{code}: #{msg}"])
  end

  defp decode_api_error(error) do
    ResponseInvalid.exception(errors: ["Unknown error: #{inspect(error)}"])
  end

  # --- Message Splitting ---

  defp split_messages(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &(&1.role == :system))

    instructions =
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

    {instructions, rest}
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

  # --- Input Encoding ---

  defp encode_input(messages) do
    {:ok, Enum.flat_map(messages, &encode_input_item/1)}
  end

  defp encode_input_item(%Message{role: :user, content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp encode_input_item(%Message{role: :user, content: parts}) when is_list(parts) do
    [%{"role" => "user", "content" => Enum.map(parts, &encode_user_content_part/1)}]
  end

  defp encode_input_item(%Message{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    {reasoning_items, message_content} = split_reasoning_content(content)
    assistant_item = encode_assistant_item(message_content)

    function_call_items =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => name,
          "arguments" => JSON.encode!(args)
        }
      end)

    reasoning_items ++ [assistant_item | function_call_items]
  end

  defp encode_input_item(%Message{role: :assistant, content: content}) do
    {reasoning_items, message_content} = split_reasoning_content(content)
    reasoning_items ++ [encode_assistant_item(message_content)]
  end

  defp encode_input_item(%Message{role: :tool_result, content: content, tool_call_id: id}) do
    [%{"type" => "function_call_output", "call_id" => id, "output" => to_string(content)}]
  end

  defp encode_assistant_item(nil) do
    %{"type" => "message", "role" => "assistant", "status" => "completed", "content" => []}
  end

  defp encode_assistant_item(content) when is_binary(content) do
    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => content}]
    }
  end

  defp encode_assistant_item(parts) when is_list(parts) do
    content =
      parts
      |> Enum.map(&encode_assistant_content_part/1)
      |> Enum.reject(&is_nil/1)

    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => content
    }
  end

  defp encode_user_content_part(%Content.Text{text: text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp encode_user_content_part(%Content.Image{url: url}) when is_binary(url) do
    %{"type" => "input_image", "image_url" => url}
  end

  defp encode_user_content_part(%Content.Image{data: data, media_type: media_type})
       when is_binary(data) do
    %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{data}"}
  end

  defp encode_assistant_content_part(%Content.Text{text: text}) do
    %{"type" => "output_text", "text" => text}
  end

  defp split_reasoning_content(content) when is_binary(content), do: {[], content}
  defp split_reasoning_content(nil), do: {[], nil}

  defp split_reasoning_content(parts) when is_list(parts) do
    {reasoning_parts, message_parts} =
      Enum.split_with(parts, fn
        %Content.Thinking{} -> true
        %Content.RedactedThinking{} -> true
        _ -> false
      end)

    reasoning_items = encode_reasoning_input_items(reasoning_parts)

    message_content =
      case message_parts do
        [] -> nil
        _ -> message_parts
      end

    {reasoning_items, message_content}
  end

  defp encode_reasoning_input_items([]), do: []

  defp encode_reasoning_input_items(parts) do
    content =
      Enum.flat_map(parts, fn
        %Content.Thinking{text: text} ->
          [%{"type" => "reasoning_text", "text" => text}]

        %Content.RedactedThinking{} ->
          []
      end)

    encrypted =
      Enum.find_value(parts, fn
        %Content.RedactedThinking{data: data} -> data
        _ -> nil
      end)

    id =
      Enum.find_value(parts, fn
        %Content.Thinking{id: id} when is_binary(id) -> id
        _ -> nil
      end)

    item =
      %{"type" => "reasoning"}
      |> then(fn i -> if id, do: Map.put(i, "id", id), else: i end)
      |> then(fn i -> if content != [], do: Map.put(i, "content", content), else: i end)
      |> then(fn i -> if encrypted, do: Map.put(i, "encrypted_content", encrypted), else: i end)

    [item]
  end

  # --- Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    {:ok,
     %{
       "type" => "function",
       "name" => name,
       "description" => description,
       "parameters" => set_strict_additional_properties(parameters),
       "strict" => true
     }}
  end

  # --- Param Translation ---

  defp translate_params(params) when is_map(params) do
    Enum.reduce(@param_map, %{}, fn {canonical, wire_key}, acc ->
      case Map.get(params, canonical) do
        nil -> acc
        value -> Map.put(acc, wire_key, value)
      end
    end)
    |> maybe_put_reasoning(params)
  end

  defp maybe_put_reasoning(payload, params) do
    reasoning =
      %{}
      |> maybe_put("effort", Map.get(params, :reasoning_effort))
      |> maybe_put("summary", Map.get(params, :reasoning_summary))

    if map_size(reasoning) > 0 do
      Map.put(payload, "reasoning", reasoning)
    else
      payload
    end
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_atom(value),
    do: Map.put(map, key, Atom.to_string(value))

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Payload Assembly ---

  defp build_payload(request, instructions, input) do
    base =
      maybe_put_field(%{"model" => request.model, "input" => input}, "instructions", instructions)

    with {:ok, payload} <- maybe_put_tools(base, request.tools),
         {:ok, payload} <- maybe_put_text(payload, request.response_schema, request.params) do
      payload =
        payload
        |> maybe_put_stream(request.stream)
        |> maybe_put_tool_choice(request.params)
        |> maybe_put_truncation(request.params)
        |> maybe_put_stream_options(request.params)
        |> maybe_put_context_management(request.params)
        |> Map.merge(translate_params(request.params))

      {:ok, payload}
    end
  end

  defp maybe_put_stream(payload, nil), do: payload
  defp maybe_put_stream(payload, _callback), do: Map.put(payload, "stream", true)

  defp maybe_put_field(payload, _key, nil), do: payload
  defp maybe_put_field(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_tool_choice(payload, %{tool_choice: :auto}),
    do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, %{tool_choice: :none}),
    do: Map.put(payload, "tool_choice", "none")

  defp maybe_put_tool_choice(payload, %{tool_choice: :any}),
    do: Map.put(payload, "tool_choice", "required")

  defp maybe_put_tool_choice(payload, %{tool_choice: {:tool, name}}) do
    Map.put(payload, "tool_choice", %{
      "type" => "allowed_tools",
      "mode" => "required",
      "tools" => [%{"type" => "function", "name" => name}]
    })
  end

  defp maybe_put_tool_choice(payload, _), do: payload

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    {:ok, encoded} = encode_tools(tools)
    {:ok, Map.put(payload, "tools", encoded)}
  end

  defp maybe_put_text(payload, nil, %{verbosity: verbosity}) when not is_nil(verbosity) do
    {:ok, Map.put(payload, "text", %{"verbosity" => Atom.to_string(verbosity)})}
  end

  defp maybe_put_text(payload, nil, _params), do: {:ok, payload}

  defp maybe_put_text(payload, schema, params) do
    {:ok, format} = encode_response_schema(schema)
    text = %{"format" => format}
    text = maybe_put(text, "verbosity", Map.get(params, :verbosity))
    {:ok, Map.put(payload, "text", text)}
  end

  defp maybe_put_truncation(payload, %{truncation: truncation}) when not is_nil(truncation),
    do: Map.put(payload, "truncation", Atom.to_string(truncation))

  defp maybe_put_truncation(payload, _), do: payload

  defp maybe_put_stream_options(payload, %{stream_options: opts}) when not is_nil(opts),
    do: Map.put(payload, "stream_options", opts)

  defp maybe_put_stream_options(payload, _), do: payload

  defp maybe_put_context_management(payload, %{context_management: config})
       when not is_nil(config),
       do: Map.put(payload, "context_management", config)

  defp maybe_put_context_management(payload, _), do: payload

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

  defp map_finish_reason("completed"), do: :stop
  defp map_finish_reason("failed"), do: :error
  defp map_finish_reason("incomplete"), do: :incomplete
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(_), do: :unknown
end
