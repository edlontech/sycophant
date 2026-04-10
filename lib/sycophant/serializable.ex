defprotocol Sycophant.Serializable do
  @moduledoc """
  Protocol for converting Sycophant structs to plain maps for JSON serialization.

  Every implementation includes a `"__type__"` discriminator key that enables
  round-trip decoding via `Sycophant.Serializable.Decoder`.

  ## Round-trip Example

      response = %Sycophant.Response{...}
      json = Sycophant.Serializable.Decoder.encode(response)
      restored = Sycophant.Serializable.Decoder.decode(json)

  All core structs implement this protocol: `Response`, `Context`, `Message`,
  `Tool`, `ToolCall`, `Usage`, `Reasoning`, `EmbeddingRequest`,
  `EmbeddingResponse`, `EmbeddingParams`, and content parts.
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
  Decodes plain maps back into Sycophant structs using `"__type__"` discriminators.

  Provides `encode/1` and `decode/1` convenience functions for full JSON
  round-tripping, as well as `from_map/2` for working with already-parsed maps.

  ## Examples

      # Full JSON round-trip
      json = Sycophant.Serializable.Decoder.encode(response)
      restored = Sycophant.Serializable.Decoder.decode(json)

      # From a pre-parsed map
      map = %{"__type__" => "Usage", "input_tokens" => 10, "output_tokens" => 25}
      usage = Sycophant.Serializable.Decoder.from_map(map)

  ## Tool Registry

  When decoding `Tool` structs, pass a `:tool_registry` option to restore
  function references (which cannot be serialized):

      registry = %{"get_weather" => &MyApp.get_weather/1}
      Sycophant.Serializable.Decoder.decode(json, tool_registry: registry)
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
  def from_map(%{"__type__" => "Pricing"} = data, _opts), do: Sycophant.Pricing.from_map(data)

  def from_map(%{"__type__" => "PricingComponent"} = data, _opts),
    do: Sycophant.Pricing.Component.from_map(data)

  def from_map(%{"__type__" => "EmbeddingParams"} = data, _opts),
    do: Sycophant.EmbeddingParams.from_map(data)

  def from_map(%{"__type__" => "EmbeddingRequest"} = data, _opts),
    do: Sycophant.EmbeddingRequest.from_map(data)

  def from_map(%{"__type__" => "EmbeddingResponse"} = data, _opts),
    do: Sycophant.EmbeddingResponse.from_map(data)

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
