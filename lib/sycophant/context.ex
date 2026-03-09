defmodule Sycophant.Context do
  @moduledoc """
  Internal conversation state held inside Response.

  Carries the full message history and configuration needed
  for continuation calls. Credentials are intentionally excluded —
  they are resolved fresh per-call. Wire protocol lives on individual
  messages to support mid-conversation model swaps.
  """
  use TypedStruct

  alias Sycophant.Serializable.Decoder

  typedstruct do
    field :messages, [Sycophant.Message.t()], enforce: true
    field :model, String.t()
    field :params, Sycophant.Params.t()
    field :provider_params, map(), default: %{}
    field :tools, [Sycophant.Tool.t()], default: []
    field :stream, (term() -> term())
    field :response_schema, Zoi.schema()
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])

    %__MODULE__{
      messages: Enum.map(data["messages"], &Decoder.from_map/1),
      model: data["model"],
      params: decode_optional(data["params"]),
      provider_params: data["provider_params"] || %{},
      tools: decode_tools(data["tools"], opts),
      stream: nil,
      response_schema: data["response_schema"]
    }
  end

  defp decode_optional(nil), do: nil
  defp decode_optional(data), do: Decoder.from_map(data)

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
      "params" => maybe_to_map(ctx.params),
      "provider_params" => non_empty_map(ctx.provider_params),
      "tools" => encode_tools(ctx.tools),
      "response_schema" => encode_schema(ctx.response_schema)
    })
  end

  defp maybe_to_map(nil), do: nil
  defp maybe_to_map(struct), do: Sycophant.Serializable.to_map(struct)

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

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
