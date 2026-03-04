defmodule Sycophant.Context do
  @moduledoc """
  Internal conversation state held inside Response.

  Carries the full message history and configuration needed
  for continuation calls. Credentials are intentionally excluded —
  they are resolved fresh per-call. Wire protocol lives on individual
  messages to support mid-conversation model swaps.
  """
  use TypedStruct

  typedstruct do
    field(:messages, [Sycophant.Message.t()], enforce: true)
    field(:model, String.t())
    field(:params, Sycophant.Params.t())
    field(:provider_params, map(), default: %{})
    field(:tools, [Sycophant.Tool.t()], default: [])
    field(:stream, (term() -> term()))
  end
end
