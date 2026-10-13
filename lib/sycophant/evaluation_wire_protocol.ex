defmodule Sycophant.EvaluationWireProtocol do
  @moduledoc """
  Behaviour for evaluation wire protocol adapters.

  Each adapter translates between Sycophant's canonical `EvaluationRequest`
  and a provider-specific HTTP format for the `:evaluate` model kind.

  ## Built-in Adapters

    * `Sycophant.EvaluationWireProtocol.TypesafeSystemone` - TypeSafe System One evaluation API
    * `Sycophant.EvaluationWireProtocol.OpenRouterDecisions` - OpenRouter Decisions API
    * `Sycophant.EvaluationWireProtocol.OpenAIDecisions` - OpenAI Decisions API
  """

  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationResponse

  @callback request_path(EvaluationRequest.t()) :: String.t()
  @callback encode_request(EvaluationRequest.t()) :: {:ok, map()} | {:error, Splode.Error.t()}
  @doc """
  Decodes the provider response body into an `EvaluationResponse`.

  Receives the originating `EvaluationRequest` so adapters that return
  answers positionally (for example OpenAI Decisions) can check the answers
  against the questions that were sent. Adapters keyed by question id can
  ignore it.
  """
  @callback decode_response(
              body :: map(),
              headers :: [{String.t(), String.t()}],
              request :: EvaluationRequest.t()
            ) ::
              {:ok, EvaluationResponse.t()} | {:error, Splode.Error.t()}
end
