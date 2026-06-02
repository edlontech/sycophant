defmodule Sycophant.Serializable do
  @moduledoc """
  Encodes Sycophant structs to plain, JSON-ready maps with a `"__type__"`
  discriminator. Decoding is handled by `Sycophant.Serializable.Decoder`,
  which is driven by each struct's Zoi schema (`t/0`).
  """
  alias Sycophant.Tool

  @doc "Converts a Sycophant struct into a plain map with a `__type__` discriminator."
  @spec to_map(struct()) :: map()
  def to_map(%Tool{} = tool), do: encode_tool(tool)
  def to_map(%_{} = struct), do: struct |> Map.from_struct() |> encode_fields()

  defp encode_fields(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      case walk(v) do
        # `:__omit__` is a sentinel for "drop this field"; a real atom field value
        # `:__omit__` is stringified to `"__omit__"` by the atom clause, so it can't be wrongly dropped.
        :__omit__ -> acc
        walked -> Map.put(acc, Atom.to_string(k), walked)
      end
    end)
  end

  defp walk(nil), do: :__omit__
  defp walk([]), do: :__omit__
  defp walk(map) when map == %{}, do: :__omit__
  defp walk(fun) when is_function(fun), do: :__omit__
  defp walk(tuple) when is_tuple(tuple), do: :__omit__
  defp walk(%_{} = struct), do: to_map(struct)
  defp walk(list) when is_list(list), do: Enum.map(list, &walk_element/1)
  # Plain maps (raw/object/metadata/params/arguments) are passed through VERBATIM by design
  # (JSON stringifies keys; decode re-atomizes where needed).
  defp walk(map) when is_map(map), do: map
  defp walk(atom) when is_atom(atom) and atom not in [true, false], do: Atom.to_string(atom)
  defp walk(other), do: other

  defp walk_element(%_{} = struct), do: to_map(struct)
  defp walk_element(list) when is_list(list), do: Enum.map(list, &walk_element/1)

  defp walk_element(atom) when is_atom(atom) and atom not in [true, false] and not is_nil(atom),
    do: Atom.to_string(atom)

  defp walk_element(other), do: other

  defp encode_tool(%Tool{} = tool) do
    json_schema =
      case Sycophant.Schema.JsonSchema.to_json_schema(tool.parameters) do
        {:ok, schema} -> schema
        _ -> tool.parameters
      end

    base = %{
      "__type__" => "Tool",
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => json_schema,
      "strict" => tool.strict
    }

    if tool.schema_source,
      do: Map.put(base, "schema_source", Atom.to_string(tool.schema_source)),
      else: base
  end
end

defmodule Sycophant.Serializable.Decoder do
  @moduledoc """
  Decodes plain maps back into Sycophant structs using their `"__type__"`
  discriminator. Most types decode through their Zoi schema (`t/0`); a few
  containers post-process (tool function registry, resolved schema, etc.).
  """
  alias Sycophant.Error.Invalid.InvalidSerialization

  @registry %{
    "Text" => Sycophant.Message.Content.Text,
    "Image" => Sycophant.Message.Content.Image,
    "Document" => Sycophant.Message.Content.Document,
    "Thinking" => Sycophant.Message.Content.Thinking,
    "RedactedThinking" => Sycophant.Message.Content.RedactedThinking,
    "Citation" => Sycophant.Citation,
    "ToolCall" => Sycophant.ToolCall,
    "Usage" => Sycophant.Usage,
    "Reasoning" => Sycophant.Reasoning,
    "Pricing" => Sycophant.Pricing,
    "PricingComponent" => Sycophant.Pricing.Component,
    "EmbeddingParams" => Sycophant.EmbeddingParams,
    "EmbeddingRequest" => Sycophant.EmbeddingRequest,
    "EmbeddingResponse" => Sycophant.EmbeddingResponse,
    "Tool" => Sycophant.Tool,
    "Message" => Sycophant.Message,
    "Context" => Sycophant.Context,
    "Response" => Sycophant.Response
  }

  @doc "Serializes a struct to a JSON string."
  @spec encode(struct()) :: String.t()
  def encode(struct), do: struct |> Sycophant.Serializable.to_map() |> JSON.encode!()

  @doc "Decodes a JSON string back into a Sycophant struct."
  @spec decode(String.t(), keyword()) :: struct()
  def decode(json, opts \\ []), do: json |> JSON.decode!() |> from_map(opts)

  @doc "Reconstructs a Sycophant struct from a plain map via its `__type__`."
  @spec from_map(map(), keyword()) :: struct()
  def from_map(data, opts \\ [])

  def from_map(%{"__type__" => type} = data, opts) do
    case Map.fetch(@registry, type) do
      {:ok, module} ->
        try do
          decode_typed(module, data, opts)
        rescue
          e in Zoi.ParseError ->
            reraise InvalidSerialization.exception(
                      reason: "invalid #{type}: #{Exception.message(e)}"
                    ),
                    __STACKTRACE__
        end

      :error ->
        raise InvalidSerialization, reason: "unknown serializable type: #{inspect(type)}"
    end
  end

  def from_map(%{} = _data, _opts) do
    raise InvalidSerialization, reason: "missing __type__ key in serialized data"
  end

  defp decode_typed(Sycophant.Message, data, opts), do: Sycophant.Message.decode(data, opts)
  defp decode_typed(Sycophant.Tool, data, opts), do: Sycophant.Tool.decode(data, opts)
  defp decode_typed(Sycophant.Context, data, opts), do: Sycophant.Context.decode(data, opts)
  defp decode_typed(Sycophant.Response, data, opts), do: Sycophant.Response.decode(data, opts)

  defp decode_typed(Sycophant.EmbeddingRequest, data, opts),
    do: Sycophant.EmbeddingRequest.decode(data, opts)

  defp decode_typed(Sycophant.EmbeddingResponse, data, _opts),
    do: Sycophant.EmbeddingResponse.decode(data)

  # Default: pure schema-driven decode.
  defp decode_typed(module, data, _opts), do: Zoi.parse!(module.t(), data)

  @doc false
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  rescue
    ArgumentError -> map
  end

  def atomize_keys(value), do: value
end
