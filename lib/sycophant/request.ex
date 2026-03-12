defmodule Sycophant.Request do
  @moduledoc """
  Internal struct representing a normalized LLM request.

  Built by `Sycophant.Pipeline` after model resolution and parameter
  validation. Passed to wire protocol adapters for encoding into
  provider-specific JSON payloads. This is not part of the public API.
  """

  use TypedStruct

  typedstruct do
    field :messages, [Sycophant.Message.t()], enforce: true
    field :model, String.t()
    field :resolved_model, term()
    field :wire_protocol, atom()
    field :params, map(), default: %{}
    field :tools, [Sycophant.Tool.t()], default: []
    field :credentials, map(), default: %{}
    field :stream, (term() -> term())
    field :response_schema, term()
  end
end

defimpl Inspect, for: Sycophant.Request do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(req, opts) do
    fields =
      Enum.reject(
        [
          model: req.model,
          messages: length(req.messages),
          tools: if(req.tools != [], do: length(req.tools)),
          credentials: InspectHelpers.redact(if(req.credentials != %{}, do: req.credentials)),
          stream: InspectHelpers.fn_label(req.stream)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Request<", to_doc(Map.new(fields), opts), ">"])
  end
end
