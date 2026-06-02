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
  alias Sycophant.Message.Content
  alias Sycophant.ToolCall

  use ZoiDefstruct

  @type content_part() ::
          Content.Text.t()
          | Content.Image.t()
          | Content.Document.t()
          | Content.Thinking.t()
          | Content.RedactedThinking.t()

  @content_part Zoi.union([
                  Content.Text.t(),
                  Content.Image.t(),
                  Content.Document.t(),
                  Content.Thinking.t(),
                  Content.RedactedThinking.t()
                ])

  defstruct __type__: Zoi.literal("Message") |> Zoi.default("Message"),
            role:
              Zoi.enum(
                [
                  user: "user",
                  assistant: "assistant",
                  system: "system",
                  tool_result: "tool_result"
                ],
                coerce: true
              ),
            content: Zoi.union([Zoi.string(), Zoi.list(@content_part)]) |> Zoi.optional(),
            tool_call_id: Zoi.optional(Zoi.string()),
            tool_calls: Zoi.list(Sycophant.ToolCall.t()) |> Zoi.optional(),
            metadata: Zoi.default(Zoi.any(), %{}),
            wire_protocol:
              Zoi.enum(
                [
                  anthropic_messages: "anthropic_messages",
                  openai_completions: "openai_completions",
                  openai_responses: "openai_responses",
                  bedrock_converse: "bedrock_converse",
                  google_gemini: "google_gemini"
                ],
                coerce: true
              )
              |> Zoi.optional()

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

  @doc false
  @spec decode(map(), keyword()) :: t()
  def decode(data, _opts) do
    msg = Zoi.parse!(__MODULE__.t(), data)
    %{msg | metadata: fix_metadata(msg.metadata)}
  end

  defp fix_metadata(meta) when is_map(meta) do
    Map.new(meta, fn
      {"tool_name", v} -> {:tool_name, v}
      {k, v} -> {k, v}
    end)
  end
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
