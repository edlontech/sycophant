defmodule Sycophant.Message do
  @moduledoc """
  Represents a message in a conversation.

  Use the constructor functions `user/1`, `assistant/1`, `system/1`,
  and `tool_result/2` to create messages with the correct role.
  """
  use TypedStruct

  alias Sycophant.Message.Content
  alias Sycophant.ToolCall

  @type content_part() :: Content.Text.t() | Content.Image.t()

  typedstruct do
    field(:role, :user | :assistant | :system | :tool_result, enforce: true)
    field(:content, String.t() | [content_part()])
    field(:tool_call_id, String.t())
    field(:tool_calls, [ToolCall.t()])
    field(:metadata, map(), default: %{})
    field(:wire_protocol, atom())
  end

  @spec user(String.t() | [content_part()]) :: t()
  def user(content), do: %__MODULE__{role: :user, content: content}

  @spec assistant(String.t() | [content_part()]) :: t()
  def assistant(content), do: %__MODULE__{role: :assistant, content: content}

  @spec system(String.t() | [content_part()]) :: t()
  def system(content), do: %__MODULE__{role: :system, content: content}

  @spec tool_result(ToolCall.t(), String.t()) :: t()
  def tool_result(%ToolCall{id: id}, result) do
    %__MODULE__{role: :tool_result, content: result, tool_call_id: id}
  end
end
