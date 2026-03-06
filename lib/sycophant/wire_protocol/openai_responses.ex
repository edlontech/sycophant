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
  alias Sycophant.Params
  alias Sycophant.Reasoning
  alias Sycophant.Request
  alias Sycophant.Response
  alias Sycophant.Schema.JsonSchema
  alias Sycophant.StreamChunk
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  @param_map %{
    temperature: "temperature",
    max_tokens: "max_output_tokens",
    top_p: "top_p",
    parallel_tool_calls: "parallel_tool_calls",
    service_tier: "service_tier",
    cache_key: "prompt_cache_key",
    cache_retention: "prompt_cache_retention",
    safety_identifier: "safety_identifier"
  }

  @dropped_params [:top_k, :stop, :seed, :frequency_penalty, :presence_penalty, :tool_choice]

  @impl true
  def encode_request(%Request{} = request) do
    {instructions, input_messages} = split_messages(request.messages)

    with {:ok, input} <- encode_input(input_messages) do
      build_payload(request, instructions, input)
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
      {:ok,
       %{
         "type" => "json_schema",
         "name" => "response",
         "strict" => true,
         "schema" => set_strict_additional_properties(json_schema)
       }}
    end
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
      {:ok, texts, tcs, reasoning} ->
        text =
          case Enum.reverse(texts) do
            [] -> nil
            parts -> Enum.join(parts, "")
          end

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

  defp process_output_item(%{"type" => "reasoning", "summary" => summary})
       when is_list(summary) do
    summary_text =
      summary
      |> Enum.filter(&(&1["type"] == "summary_text"))
      |> Enum.map_join("", & &1["text"])

    reasoning =
      if summary_text == "" do
        nil
      else
        %Reasoning{summary: summary_text}
      end

    {:reasoning, reasoning}
  end

  defp process_output_item(%{"type" => "reasoning", "encrypted_content" => encrypted}) do
    {:reasoning, %Reasoning{encrypted_content: encrypted}}
  end

  defp process_output_item(%{"type" => "reasoning"}) do
    :skip
  end

  defp process_output_item(_other) do
    :skip
  end

  defp decode_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"])

    %Usage{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached
    }
  end

  defp decode_usage(_), do: nil

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
            |> Enum.map(& &1.content)
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> Enum.join("\n")

          if joined == "", do: nil, else: joined
      end

    {instructions, rest}
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
    assistant_item = encode_assistant_item(content)

    function_call_items =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => name,
          "arguments" => JSON.encode!(args)
        }
      end)

    [assistant_item | function_call_items]
  end

  defp encode_input_item(%Message{role: :assistant, content: content}) do
    [encode_assistant_item(content)]
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
    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => Enum.map(parts, &encode_assistant_content_part/1)
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

  # --- Tool Encoding ---

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(parameters) do
      {:ok,
       %{
         "type" => "function",
         "name" => name,
         "description" => description,
         "parameters" => set_strict_additional_properties(json_schema),
         "strict" => true
       }}
    end
  end

  # --- Param Translation ---

  defp translate_params(nil), do: %{}

  defp translate_params(%Params{} = params) do
    params
    |> Map.from_struct()
    |> Enum.reject(fn {k, v} ->
      is_nil(v) or k in @dropped_params or k in [:reasoning, :reasoning_summary]
    end)
    |> Map.new(&translate_param/1)
    |> maybe_put_reasoning(params)
  end

  defp translate_param({key, value}), do: {Map.fetch!(@param_map, key), value}

  defp maybe_put_reasoning(payload, %Params{reasoning: nil, reasoning_summary: nil}), do: payload

  defp maybe_put_reasoning(payload, %Params{} = params) do
    reasoning =
      %{}
      |> maybe_put("effort", params.reasoning)
      |> maybe_put("summary", params.reasoning_summary)

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
         {:ok, payload} <- maybe_put_text_format(payload, request.response_schema) do
      payload =
        payload
        |> maybe_put_stream(request.stream)
        |> maybe_put_tool_choice(request.params)
        |> Map.merge(translate_params(request.params))
        |> Map.merge(request.provider_params || %{})

      {:ok, payload}
    end
  end

  defp maybe_put_stream(payload, nil), do: payload
  defp maybe_put_stream(payload, _callback), do: Map.put(payload, "stream", true)

  defp maybe_put_field(payload, _key, nil), do: payload
  defp maybe_put_field(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_tool_choice(payload, nil), do: payload
  defp maybe_put_tool_choice(payload, %Params{tool_choice: nil}), do: payload

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :auto}),
    do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :none}),
    do: Map.put(payload, "tool_choice", "none")

  defp maybe_put_tool_choice(payload, %Params{tool_choice: :any}),
    do: Map.put(payload, "tool_choice", "required")

  defp maybe_put_tool_choice(payload, %Params{tool_choice: {:tool, name}}) do
    Map.put(payload, "tool_choice", %{
      "type" => "allowed_tools",
      "mode" => "required",
      "tools" => [%{"type" => "function", "name" => name}]
    })
  end

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    case encode_tools(tools) do
      {:ok, encoded} -> {:ok, Map.put(payload, "tools", encoded)}
      {:error, _} = err -> err
    end
  end

  defp maybe_put_text_format(payload, nil), do: {:ok, payload}

  defp maybe_put_text_format(payload, schema) do
    case encode_response_schema(schema) do
      {:ok, format} -> {:ok, Map.put(payload, "text", %{"format" => format})}
      {:error, _} = err -> err
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
end
