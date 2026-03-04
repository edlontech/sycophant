defmodule Sycophant.WireProtocol.OpenAICompletions do
  @moduledoc """
  Wire protocol adapter for the OpenAI Chat Completions API format.

  Encodes Sycophant Request structs into the `/v1/chat/completions`
  JSON format and decodes responses back into Response structs.
  Used by any provider that implements the OpenAI-compatible API
  (OpenAI, OpenRouter, Together, DeepInfra, etc.).
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
  alias Sycophant.Tool
  alias Sycophant.ToolCall
  alias Sycophant.Usage

  @param_map %{
    temperature: "temperature",
    max_tokens: "max_completion_tokens",
    top_p: "top_p",
    stop: "stop",
    seed: "seed",
    frequency_penalty: "frequency_penalty",
    presence_penalty: "presence_penalty",
    parallel_tool_calls: "parallel_tool_calls",
    service_tier: "service_tier"
  }

  @dropped_params [:top_k, :cache_key, :cache_retention, :safety_identifier]

  @impl true
  def encode_request(%Request{} = request) do
    with {:ok, messages} <- encode_messages(request.messages) do
      build_payload(request, messages)
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
         "json_schema" => %{
           "name" => "response",
           "strict" => true,
           "schema" => set_strict_additional_properties(json_schema)
         }
       }}
    end
  end

  @impl true
  def decode_response(%{"choices" => [%{"message" => message} | _]} = body) do
    with {:ok, tool_calls} <- decode_tool_calls(message["tool_calls"]) do
      response = %Response{
        text: message["content"],
        tool_calls: tool_calls,
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
  def decode_stream_chunk(_chunk) do
    raise "Streaming is not yet implemented (planned for M6)"
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

  defp decode_usage(%{"prompt_tokens" => input, "completion_tokens" => output}) do
    %Usage{input_tokens: input, output_tokens: output}
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

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters}) do
    with {:ok, json_schema} <- JsonSchema.to_json_schema(parameters) do
      {:ok,
       %{
         "type" => "function",
         "function" => %{
           "name" => name,
           "description" => description,
           "parameters" => set_strict_additional_properties(json_schema),
           "strict" => true
         }
       }}
    end
  end

  # --- Param Translation ---

  defp translate_params(nil), do: %{}

  defp translate_params(%Params{} = params) do
    params
    |> Map.from_struct()
    |> Enum.reject(fn {k, v} -> is_nil(v) or k in @dropped_params end)
    |> Map.new(&translate_param/1)
  end

  defp translate_param({:reasoning, value}), do: {"reasoning_effort", stringify_atom(value)}

  defp translate_param({:reasoning_summary, value}),
    do: {"reasoning_summary", stringify_atom(value)}

  defp translate_param({key, value}), do: {Map.fetch!(@param_map, key), value}

  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value), do: value

  # --- Payload Assembly ---

  defp build_payload(request, messages) do
    base = %{"model" => request.model, "messages" => messages}

    with {:ok, payload} <- maybe_put_tools(base, request.tools),
         {:ok, payload} <- maybe_put_response_format(payload, request.response_schema) do
      {:ok, Map.merge(payload, translate_params(request.params))}
    end
  end

  defp maybe_put_tools(payload, []), do: {:ok, payload}

  defp maybe_put_tools(payload, tools) do
    case encode_tools(tools) do
      {:ok, encoded} -> {:ok, Map.put(payload, "tools", encoded)}
      {:error, _} = err -> err
    end
  end

  defp maybe_put_response_format(payload, nil), do: {:ok, payload}

  defp maybe_put_response_format(payload, schema) do
    case encode_response_schema(schema) do
      {:ok, format} -> {:ok, Map.put(payload, "response_format", format)}
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
