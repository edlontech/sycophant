defmodule Sycophant.Request do
  @moduledoc """
  Internal struct representing a normalized LLM request.

  Built by `Sycophant.Pipeline` after model resolution and parameter
  validation. Passed to wire protocol adapters for encoding.
  """

  use TypedStruct

  typedstruct do
    field :messages, [Sycophant.Message.t()], enforce: true
    field :model, String.t()
    field :resolved_model, term()
    field :wire_protocol, atom()
    field :params, Sycophant.Params.t()
    field :provider_params, map(), default: %{}
    field :tools, [Sycophant.Tool.t()], default: []
    field :credentials, map(), default: %{}
    field :stream, (term() -> term())
    field :response_schema, term()
  end
end
