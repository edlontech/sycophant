defmodule Sycophant.WireProtocol do
  @moduledoc """
  Behaviour for chat wire protocol adapters.

  Wire protocol adapters encode `Sycophant.Request` structs into
  provider-specific JSON payloads and decode provider responses back
  into `Sycophant.Response` structs. Dispatch is by wire protocol
  metadata from LLMDB, not by provider identity.

  ## Built-in Adapters

    * `Sycophant.WireProtocol.OpenAICompletions` - OpenAI Chat Completions API
    * `Sycophant.WireProtocol.OpenAIResponses` - OpenAI Responses API
    * `Sycophant.WireProtocol.AnthropicMessages` - Anthropic Messages API
    * `Sycophant.WireProtocol.GoogleGemini` - Google Gemini API
    * `Sycophant.WireProtocol.BedrockConverse` - AWS Bedrock Converse API
  """

  @callback request_path(Sycophant.Request.t()) :: String.t()

  @callback encode_request(Sycophant.Request.t()) ::
              {:ok, map()} | {:error, Splode.Error.t()}

  @callback decode_response(map()) ::
              {:ok, Sycophant.Response.t()} | {:error, Splode.Error.t()}

  @callback init_stream() :: term()

  @callback decode_stream_chunk(state :: term(), event :: map()) ::
              {:ok, term(), [Sycophant.StreamChunk.t()]}
              | {:done, Sycophant.Response.t()}
              | {:done, Sycophant.Response.t(), [Sycophant.StreamChunk.t()]}
              | {:error, Splode.Error.t()}

  @callback encode_tools([Sycophant.Tool.t()]) ::
              {:ok, [map()]} | {:error, Splode.Error.t()}

  @callback encode_response_schema(Zoi.schema()) ::
              {:ok, map()} | {:error, Splode.Error.t()}

  @callback stream_transport() :: :sse | :event_stream

  @callback param_schema() :: Zoi.schema()

  @optional_callbacks [stream_transport: 0]
end
