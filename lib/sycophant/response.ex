defmodule Sycophant.Response do
  @moduledoc """
  The result of an LLM call.

  Contains the generated text or structured object, any tool calls requested
  by the model, token usage statistics, and an opaque `Context` that enables
  conversation continuation.

  ## Continuing Conversations

  Use `response.context` with `Context.add/2` to continue the conversation:

      {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
      ctx = response.context |> Context.add(Message.user("Tell me more"))
      {:ok, follow_up} = Sycophant.generate_text("openai:gpt-4o-mini", ctx)

  ## Inspecting History

  Use `messages/1` to retrieve the full conversation history:

      Response.messages(response)
      #=> [%Message{role: :user, ...}, %Message{role: :assistant, ...}]

  ## Serialization

  Responses support JSON persistence via `Sycophant.Serializable.Decoder`:

      json = Sycophant.Serializable.Decoder.encode(response)
      restored = Sycophant.Serializable.Decoder.decode(json)
  """
  alias Sycophant.Reasoning

  use ZoiDefstruct

  @type finish_reason() ::
          :stop
          | :tool_use
          | :max_tokens
          | :content_filter
          | :recitation
          | :error
          | :incomplete
          | :unknown
          | nil

  @finish_reason Zoi.transform(Zoi.string(), &__MODULE__.coerce_finish_reason/1)

  defstruct __type__: Zoi.literal("Response") |> Zoi.default("Response"),
            text: Zoi.optional(Zoi.string()),
            object: Zoi.optional(Zoi.any()),
            tool_calls: Zoi.list(Sycophant.ToolCall.t()) |> Zoi.default([]),
            citations: Zoi.list(Sycophant.Citation.t()) |> Zoi.default([]),
            usage: Zoi.optional(Sycophant.Usage.t()),
            model: Zoi.optional(Zoi.string()),
            raw: Zoi.optional(Zoi.any()),
            reasoning: Zoi.optional(Sycophant.Reasoning.t()),
            finish_reason: @finish_reason |> Zoi.optional(),
            context: Zoi.optional(Sycophant.Context.t()),
            metadata: Zoi.default(Zoi.any(), %{})

  @doc """
  Returns the full conversation message history from the response context.

  The list includes all user, assistant, system, and tool result messages
  exchanged during the conversation.
  """
  @spec messages(t()) :: [Sycophant.Message.t()]
  def messages(%__MODULE__{context: context}), do: context.messages

  @doc "Returns the response text."
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{text: text}), do: text

  @doc "Returns the first reasoning content text, if present."
  @spec reasoning_text(t()) :: String.t() | nil
  def reasoning_text(%__MODULE__{reasoning: %Reasoning{content: [%{text: t} | _]}})
      when is_binary(t), do: t

  def reasoning_text(_), do: nil

  @valid_finish_reasons ~w(stop tool_use max_tokens content_filter recitation error incomplete unknown)a

  @doc false
  @spec coerce_finish_reason(String.t()) :: finish_reason()
  def coerce_finish_reason(s) when is_binary(s) do
    atom =
      try do
        String.to_existing_atom(s)
      rescue
        _ -> :unknown
      end

    if atom in @valid_finish_reasons, do: atom, else: :unknown
  end

  @doc false
  @spec decode(map(), keyword()) :: t()
  def decode(data, opts) do
    resp = Zoi.parse!(__MODULE__.t(), Map.delete(data, "context"))

    %{
      resp
      | context: Sycophant.Context.decode(data["context"], opts),
        metadata: Sycophant.Serializable.Decoder.atomize_keys(data["metadata"] || %{})
    }
  end
end

defimpl Inspect, for: Sycophant.Response do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(resp, opts) do
    fields =
      Enum.reject(
        [
          text: InspectHelpers.truncate(resp.text),
          object: InspectHelpers.truncate_inspect(resp.object),
          model: resp.model,
          finish_reason: resp.finish_reason,
          tool_calls: length(resp.tool_calls),
          usage: resp.usage
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Response<", to_doc(Map.new(fields), opts), ">"])
  end
end
