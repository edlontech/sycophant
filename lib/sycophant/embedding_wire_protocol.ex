defmodule Sycophant.EmbeddingWireProtocol do
  @moduledoc """
  Behaviour for embedding wire protocol adapters.

  Each adapter translates between Sycophant's canonical `EmbeddingRequest`
  and a provider-specific HTTP format.

  ## Built-in Adapters

    * `Sycophant.EmbeddingWireProtocol.BedrockEmbed` - AWS Bedrock embedding API
    * `Sycophant.EmbeddingWireProtocol.OpenAIEmbed` - OpenAI-compatible embedding API (used by Azure)
  """

  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse

  @callback request_path(EmbeddingRequest.t()) :: String.t()
  @callback encode_request(EmbeddingRequest.t()) :: {:ok, map()} | {:error, Splode.Error.t()}
  @callback decode_response(body :: map(), headers :: [{String.t(), String.t()}]) ::
              {:ok, EmbeddingResponse.t()} | {:error, Splode.Error.t()}
end
