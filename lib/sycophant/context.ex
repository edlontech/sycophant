defmodule Sycophant.Context do
  @moduledoc """
  Internal conversation state held inside a `Response`.

  Carries the full message history and configuration needed for continuation
  calls. This is an opaque struct -- you typically don't interact with it
  directly. Instead, pass the entire `Response` to `Sycophant.generate_text/2`
  to continue a conversation.

  Credentials are intentionally excluded from the context and resolved fresh
  on each call. Wire protocol tags live on individual messages to support
  mid-conversation model swaps.
  """
  use TypedStruct

  alias Sycophant.Serializable.Decoder

  typedstruct do
    field :messages, [Sycophant.Message.t()], enforce: true
    field :model, String.t()
    field :params, map(), default: %{}
    field :tools, [Sycophant.Tool.t()], default: []
    field :stream, (term() -> term())
    field :response_schema, Zoi.schema()
  end

  @doc "Deserializes a context from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])

    %__MODULE__{
      messages: Enum.map(data["messages"], &Decoder.from_map/1),
      model: data["model"],
      params: decode_params(data["params"]),
      tools: decode_tools(data["tools"], opts),
      stream: nil,
      response_schema: data["response_schema"]
    }
  end

  defp decode_params(nil), do: %{}

  defp decode_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  rescue
    ArgumentError -> params
  end

  defp decode_tools(nil, _opts), do: []

  defp decode_tools(tools, opts),
    do: Enum.map(tools, &Decoder.from_map(Map.put(&1, :opts, opts), opts))
end

defimpl Sycophant.Serializable, for: Sycophant.Context do
  import Sycophant.Serializable.Helpers

  def to_map(ctx) do
    compact(%{
      "__type__" => "Context",
      "messages" => Enum.map(ctx.messages, &Sycophant.Serializable.to_map/1),
      "model" => ctx.model,
      "params" => encode_params(ctx.params),
      "tools" => encode_tools(ctx.tools),
      "response_schema" => encode_schema(ctx.response_schema)
    })
  end

  defp encode_params(params) when map_size(params) == 0, do: nil

  defp encode_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp encode_tools([]), do: nil
  defp encode_tools(tools), do: Enum.map(tools, &Sycophant.Serializable.to_map/1)

  defp encode_schema(nil), do: nil

  defp encode_schema(schema) do
    case Sycophant.Schema.JsonSchema.to_json_schema(schema) do
      {:ok, json_schema} -> json_schema
      _ -> nil
    end
  end
end
