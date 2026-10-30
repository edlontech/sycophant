defmodule Sycophant.MessageCompat do
  @moduledoc false

  require Logger

  alias Sycophant.Message
  alias Sycophant.Message.Content.RedactedThinking
  alias Sycophant.Message.Content.Thinking

  @type origin :: {provider :: atom(), wire_protocol :: atom() | nil}

  @max_id_length 64

  @doc """
  Adapts a message history so the target origin's wire can encode it.

  Assistant turns produced by another provider or wire protocol lose their
  reasoning parts and Gemini thought signatures, since only the issuing
  provider can verify them; a turn left empty is removed. Untagged turns are
  kept as-is.

  Tool call IDs are then made valid for every provider (`[A-Za-z0-9_-]`, at
  most 64 characters) and unique, with each tool result following the most
  recent call that had its original ID. Valid unique IDs are left unchanged.

  The same input always yields the same output, which keeps provider-side
  signature binding and prompt caching stable.
  """
  @spec adapt([Message.t()], origin()) :: [Message.t()]
  def adapt(messages, origin) do
    messages
    |> strip_foreign_reasoning(origin)
    |> normalize_tool_call_ids()
  end

  defp strip_foreign_reasoning(messages, origin) do
    adapted = Enum.flat_map(messages, &strip_foreign(&1, origin))

    if adapted != messages do
      Logger.debug(
        "Dropped reasoning from other providers' assistant turns " <>
          "(#{length(messages) - length(adapted)} turn(s) removed)"
      )
    end

    adapted
  end

  defp strip_foreign(
         %Message{role: :assistant, provider: provider, wire_protocol: wire} = msg,
         origin
       )
       when not is_nil(provider) and {provider, wire} != origin do
    content = drop_reasoning(msg.content)
    tool_calls = Enum.map(msg.tool_calls || [], &drop_thought_signature/1)

    case {content, tool_calls} do
      {nil, []} -> []
      {content, []} -> [%{msg | content: content, tool_calls: nil}]
      {content, tool_calls} -> [%{msg | content: content, tool_calls: tool_calls}]
    end
  end

  defp strip_foreign(msg, _origin), do: [msg]

  defp drop_reasoning(parts) when is_list(parts) do
    case Enum.reject(parts, &(is_struct(&1, Thinking) or is_struct(&1, RedactedThinking))) do
      [] -> nil
      rest -> rest
    end
  end

  defp drop_reasoning(content), do: content

  defp drop_thought_signature(tool_call),
    do: %{tool_call | metadata: Map.delete(tool_call.metadata, :thought_signature)}

  defp normalize_tool_call_ids(messages) do
    {adapted, _state} = Enum.map_reduce(messages, %{map: %{}, used: MapSet.new()}, &rewrite_ids/2)
    adapted
  end

  defp rewrite_ids(%Message{role: :assistant, tool_calls: [_ | _] = tool_calls} = msg, state) do
    {tool_calls, state} =
      Enum.map_reduce(tool_calls, state, fn tool_call, state ->
        id = unique_id(sanitize_id(tool_call.id), state.used)

        {%{tool_call | id: id},
         %{state | map: Map.put(state.map, tool_call.id, id), used: MapSet.put(state.used, id)}}
      end)

    {%{msg | tool_calls: tool_calls}, state}
  end

  defp rewrite_ids(%Message{role: :tool_result, tool_call_id: id} = msg, state)
       when is_binary(id),
       do: {%{msg | tool_call_id: Map.get_lazy(state.map, id, fn -> sanitize_id(id) end)}, state}

  defp rewrite_ids(msg, state), do: {msg, state}

  defp sanitize_id(id) do
    case ~r/[^A-Za-z0-9_-]/ |> Regex.replace(id, "_") |> String.slice(0, @max_id_length) do
      "" -> "call"
      sanitized -> sanitized
    end
  end

  defp unique_id(base, used, counter \\ 0)

  defp unique_id(base, used, 0) do
    if MapSet.member?(used, base), do: unique_id(base, used, 1), else: base
  end

  defp unique_id(base, used, counter) do
    suffix = "_#{counter}"
    candidate = String.slice(base, 0, @max_id_length - byte_size(suffix)) <> suffix

    if MapSet.member?(used, candidate), do: unique_id(base, used, counter + 1), else: candidate
  end
end
