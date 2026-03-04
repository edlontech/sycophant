defmodule Sycophant.WireProtocol do
  @moduledoc """
  Behaviour for wire protocol adapters.

  Wire protocol adapters encode Sycophant Request structs into
  provider-specific JSON payloads and decode provider responses
  back into Response structs. Dispatch is by wire protocol, not
  provider identity.
  """

  @callback request_path() :: String.t()

  @callback encode_request(Sycophant.Request.t()) ::
              {:ok, map()} | {:error, Splode.Error.t()}

  @callback decode_response(map()) ::
              {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}

  @callback decode_stream_chunk(binary()) ::
              {:ok, list()} | {:error, Splode.Error.t()}

  @callback encode_tools([Sycophant.Tool.t()]) ::
              {:ok, [map()]} | {:error, Splode.Error.t()}

  @callback encode_response_schema(Zoi.schema()) ::
              {:ok, map()} | {:error, Splode.Error.t()}
end
