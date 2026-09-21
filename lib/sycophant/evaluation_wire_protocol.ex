defmodule Sycophant.EvaluationWireProtocol do
  @moduledoc """
  Behaviour for evaluation wire protocol adapters.

  Each adapter translates between Sycophant's canonical `EvaluationRequest`
  and a provider-specific HTTP format for the `:evaluate` model kind.

  ## Built-in Adapters

    * `Sycophant.EvaluationWireProtocol.TypesafeSystemone` - TypeSafe System One evaluation API
  """

  alias Sycophant.EvaluationRequest
  alias Sycophant.EvaluationResponse

  @callback request_path(EvaluationRequest.t()) :: String.t()
  @callback encode_request(EvaluationRequest.t()) :: {:ok, map()} | {:error, Splode.Error.t()}
  @callback decode_response(body :: map(), headers :: [{String.t(), String.t()}]) ::
              {:ok, EvaluationResponse.t()} | {:error, Splode.Error.t()}
end
