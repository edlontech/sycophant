defmodule Sycophant.EvaluationWireProtocol.OpenRouterDecisions do
  @moduledoc """
  Wire protocol adapter for OpenRouter's Decisions API.

  OpenRouter's `/api/alpha/decisions` endpoint shares the same request and
  answer shapes as TypeSafe's System One API, so encoding and decoding are
  delegated to `Sycophant.EvaluationWireProtocol.TypesafeSystemone`. OpenRouter
  bills usage in USD as `usage.cost`, which the delegate decodes into
  `Usage.total_cost`.
  """

  @behaviour Sycophant.EvaluationWireProtocol

  alias Sycophant.EvaluationWireProtocol.TypesafeSystemone

  @impl true
  def request_path(_request), do: "/api/alpha/decisions"

  @impl true
  defdelegate encode_request(request), to: TypesafeSystemone

  @impl true
  defdelegate decode_response(body, headers), to: TypesafeSystemone
end
