defmodule Sycophant.Message do
  @moduledoc """
  Represents a message in a conversation.

  Messages are the building blocks of LLM conversations. Each message has a
  `:role` and `:content`, with optional `:tool_calls` for assistant responses
  and `:tool_call_id` for tool results.

  Use the constructor functions to create messages with the correct role:

      iex> Sycophant.Message.user("Hello!")
      #Sycophant.Message<%{role: :user, content: "Hello!"}>

      iex> Sycophant.Message.system("You are helpful.")
      #Sycophant.Message<%{role: :system, content: "You are helpful."}>

      iex> Sycophant.Message.assistant("Hi there!")
      #Sycophant.Message<%{role: :assistant, content: "Hi there!"}>

  ## Multimodal Content

  Content can be a plain string or a list of content parts for multimodal input:

      Sycophant.Message.user([
        %Sycophant.Message.Content.Text{text: "What's in this image?"},
        %Sycophant.Message.Content.Image{url: "https://example.com/photo.jpg"}
      ])
  """
  use TypedStruct

  alias Sycophant.Message.Content
  alias Sycophant.ToolCall

  @type content_part() ::
          Content.Text.t()
          | Content.Image.t()
          | Content.Thinking.t()
          | Content.RedactedThinking.t()

  typedstruct do
    field :role, :user | :assistant | :system | :tool_result, enforce: true
    field :content, String.t() | [content_part()]
    field :tool_call_id, String.t()
    field :tool_calls, [ToolCall.t()]
    field :metadata, map(), default: %{}
    field :wire_protocol, atom()
  end

  @doc """
  Creates a user message with the given content.

  ## Examples

      iex> Sycophant.Message.user("What is Elixir?")
      #Sycophant.Message<%{role: :user, content: "What is Elixir?"}>
  """
  @spec user(String.t() | [content_part()]) :: t()
  def user(content), do: %__MODULE__{role: :user, content: content}

  @doc """
  Creates an assistant message with the given content.

  ## Examples

      iex> Sycophant.Message.assistant("Elixir is a functional language.")
      #Sycophant.Message<%{role: :assistant, content: "Elixir is a functional language."}>
  """
  @spec assistant(String.t() | [content_part()]) :: t()
  def assistant(content), do: %__MODULE__{role: :assistant, content: content}

  @doc """
  Creates a system message with the given content.

  ## Examples

      iex> Sycophant.Message.system("You are a helpful assistant.")
      #Sycophant.Message<%{role: :system, content: "You are a helpful assistant."}>
  """
  @spec system(String.t() | [content_part()]) :: t()
  def system(content), do: %__MODULE__{role: :system, content: content}

  @doc """
  Creates a tool result message from a tool call and its output.

  ## Examples

      iex> tool_call = %Sycophant.ToolCall{id: "call_123", name: "get_weather", arguments: %{}}
      iex> Sycophant.Message.tool_result(tool_call, "72F and sunny")
      #Sycophant.Message<%{role: :tool_result, content: "72F and sunny", tool_call_id: "call_123"}>
  """
  @spec tool_result(ToolCall.t(), String.t()) :: t()
  def tool_result(%ToolCall{id: id, name: name}, result) do
    %__MODULE__{
      role: :tool_result,
      content: result,
      tool_call_id: id,
      metadata: %{tool_name: name}
    }
  end

  alias Sycophant.Serializable.Decoder

  @role_allowlist ~w(user assistant system tool_result)

  @doc """
  Deserializes a message from a plain map produced by `Sycophant.Serializable`.

  Used internally by the serialization layer for JSON round-tripping.
  """
  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])

    %__MODULE__{
      role: safe_role(data["role"]),
      content: decode_content(data["content"], opts),
      tool_call_id: data["tool_call_id"],
      tool_calls: decode_tool_calls(data["tool_calls"], opts),
      metadata: decode_metadata(data["metadata"] || %{}),
      wire_protocol: safe_wire_protocol(data["wire_protocol"])
    }
  end

  defp safe_role(role) when role in @role_allowlist, do: String.to_existing_atom(role)

  defp safe_role(role) do
    raise Sycophant.Error.Invalid.InvalidSerialization,
      reason: "invalid role: #{inspect(role)}, expected one of: #{inspect(@role_allowlist)}"
  end

  defp decode_content(content, _opts) when is_binary(content), do: content
  defp decode_content(nil, _opts), do: nil

  defp decode_content(parts, opts) when is_list(parts),
    do: Enum.map(parts, &Decoder.from_map(&1, opts))

  defp decode_tool_calls(nil, _opts), do: nil
  defp decode_tool_calls(tcs, opts), do: Enum.map(tcs, &Decoder.from_map(&1, opts))

  defp decode_metadata(meta) do
    Map.new(meta, fn
      {"tool_name", v} -> {:tool_name, v}
      {k, v} -> {k, v}
    end)
  end

  @wire_protocols ~w(anthropic_messages openai_completions openai_responses bedrock_converse google_gemini)

  defp safe_wire_protocol(nil), do: nil
  defp safe_wire_protocol(wp) when wp in @wire_protocols, do: String.to_existing_atom(wp)

  defp safe_wire_protocol(wp) do
    raise Sycophant.Error.Invalid.InvalidSerialization,
      reason:
        "invalid wire_protocol: #{inspect(wp)}, expected one of: #{inspect(@wire_protocols)}"
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Message do
  import Sycophant.Serializable.Helpers

  def to_map(msg) do
    compact(%{
      "__type__" => "Message",
      "role" => Atom.to_string(msg.role),
      "content" => encode_content(msg.content),
      "tool_call_id" => msg.tool_call_id,
      "tool_calls" => encode_list(msg.tool_calls),
      "metadata" => encode_metadata(msg.metadata),
      "wire_protocol" => atom_to_string(msg.wire_protocol)
    })
  end

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(nil), do: nil

  defp encode_content(parts) when is_list(parts) do
    Enum.map(parts, &Sycophant.Serializable.to_map/1)
  end

  defp encode_list(nil), do: nil
  defp encode_list(list), do: Enum.map(list, &Sycophant.Serializable.to_map/1)

  defp encode_metadata(meta) when map_size(meta) == 0, do: nil
  defp encode_metadata(meta), do: Map.new(meta, fn {k, v} -> {to_string(k), v} end)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom), do: Atom.to_string(atom)
end

defimpl Inspect, for: Sycophant.Message do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(msg, opts) do
    fields =
      Enum.reject(
        [
          role: msg.role,
          content: inspect_content(msg.content),
          tool_call_id: msg.tool_call_id,
          tool_calls: inspect_tool_calls(msg.tool_calls)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Message<", to_doc(Map.new(fields), opts), ">"])
  end

  defp inspect_content(content) when is_binary(content), do: InspectHelpers.truncate(content)
  defp inspect_content(parts) when is_list(parts), do: "#{length(parts)} parts"
  defp inspect_content(nil), do: nil

  defp inspect_tool_calls(nil), do: nil
  defp inspect_tool_calls([]), do: nil
  defp inspect_tool_calls(tcs), do: "#{length(tcs)} calls"
end
