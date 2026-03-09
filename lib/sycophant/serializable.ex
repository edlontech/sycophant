defprotocol Sycophant.Serializable do
  @moduledoc """
  Protocol for converting Sycophant structs to plain maps
  suitable for JSON serialization.

  Every implementation must include a `"__type__"` discriminator
  key to enable round-trip decoding.
  """

  @fallback_to_any false

  @doc "Converts a Sycophant struct into a plain map with a `__type__` discriminator."
  @spec to_map(t()) :: map()
  def to_map(struct)
end

defmodule Sycophant.Serializable.Helpers do
  @moduledoc false

  @doc false
  @spec compact(map()) :: map()
  def compact(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end

defmodule Sycophant.Serializable.Decoder do
  @moduledoc """
  Decodes plain maps (with `"__type__"` discriminators) back
  into Sycophant structs. Provides `encode/1` and `decode/1`
  convenience functions for JSON round-tripping.
  """

  @doc "Serializes a struct to a JSON string via `Sycophant.Serializable`."
  @spec encode(struct()) :: String.t()
  def encode(struct), do: struct |> Sycophant.Serializable.to_map() |> JSON.encode!()

  @doc "Decodes a JSON string back into the appropriate Sycophant struct."
  @spec decode(String.t(), keyword()) :: struct()
  def decode(json, opts \\ []), do: json |> JSON.decode!() |> from_map(opts)

  @doc "Reconstructs a Sycophant struct from a plain map using its `__type__` discriminator."
  @spec from_map(map(), keyword()) :: struct()
  def from_map(data, opts \\ [])

  def from_map(%{"__type__" => "Text"} = data, _opts),
    do: Sycophant.Message.Content.Text.from_map(data)

  def from_map(%{"__type__" => "Image"} = data, _opts),
    do: Sycophant.Message.Content.Image.from_map(data)

  def from_map(%{"__type__" => "ToolCall"} = data, _opts), do: Sycophant.ToolCall.from_map(data)
  def from_map(%{"__type__" => "Usage"} = data, _opts), do: Sycophant.Usage.from_map(data)
  def from_map(%{"__type__" => "Reasoning"} = data, _opts), do: Sycophant.Reasoning.from_map(data)
  def from_map(%{"__type__" => "Params"} = data, _opts), do: Sycophant.Params.from_map(data)

  def from_map(%{"__type__" => "Tool"} = data, opts),
    do: Sycophant.Tool.from_map(Map.put(data, :opts, opts))

  def from_map(%{"__type__" => "Message"} = data, opts),
    do: Sycophant.Message.from_map(Map.put(data, :opts, opts))

  def from_map(%{"__type__" => "Context"} = data, opts),
    do: Sycophant.Context.from_map(Map.put(data, :opts, opts))

  def from_map(%{"__type__" => "Response"} = data, opts),
    do: Sycophant.Response.from_map(Map.put(data, :opts, opts))

  def from_map(%{"__type__" => type}, _opts) do
    raise Sycophant.Error.Invalid.InvalidSerialization,
      reason: "unknown serializable type: #{inspect(type)}"
  end

  def from_map(%{} = _data, _opts) do
    raise Sycophant.Error.Invalid.InvalidSerialization,
      reason: "missing __type__ key in serialized data"
  end
end
