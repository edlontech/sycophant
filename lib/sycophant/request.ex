defmodule Sycophant.Request do
  @moduledoc """
  Internal struct representing a normalized LLM request.

  Built by `Sycophant.Pipeline` after model resolution and parameter
  validation. Passed to wire protocol adapters for encoding into
  provider-specific JSON payloads. This is not part of the public API.
  """

  @enforce_keys [:messages]
  defstruct [
    :messages,
    :model,
    :resolved_model,
    :wire_protocol,
    :stream,
    :response_schema,
    params: %{},
    tools: [],
    credentials: %{}
  ]

  @type t :: %__MODULE__{
          messages: [Sycophant.Message.t()],
          model: String.t() | nil,
          resolved_model: term() | nil,
          wire_protocol: atom() | nil,
          params: map(),
          tools: [Sycophant.Tool.t()],
          credentials: map(),
          stream: (term() -> term()) | {term(), (term(), term() -> term())} | nil,
          response_schema: map() | nil
        }
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
