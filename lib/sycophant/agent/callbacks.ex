defmodule Sycophant.Agent.Callbacks do
  @moduledoc """
  Callback function types for agent lifecycle hooks.

  All callbacks are optional. When nil, the agent uses default behavior.
  """
  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Response
  alias Sycophant.ToolCall

  @type on_response :: (Response.t() -> :ok)
  @type on_tool_call :: (ToolCall.t() -> :approve | :reject | {:modify, ToolCall.t()})
  @type on_error ::
          (Splode.Error.t(), Context.t() ->
             :retry
             | {:retry, pos_integer()}
             | {:continue, String.t() | Message.t() | [Message.t()]}
             | {:stop, term()})
  @type on_max_steps :: (non_neg_integer(), Context.t() -> :continue | :stop)

  defstruct [:on_response, :on_tool_call, :on_error, :on_max_steps]

  @type t :: %__MODULE__{
          on_response: on_response() | nil,
          on_tool_call: on_tool_call() | nil,
          on_error: on_error() | nil,
          on_max_steps: on_max_steps() | nil
        }

  @doc "Creates a new Callbacks struct from keyword options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      on_response: opts[:on_response],
      on_tool_call: opts[:on_tool_call],
      on_error: opts[:on_error],
      on_max_steps: opts[:on_max_steps]
    }
  end
end

defimpl Inspect, for: Sycophant.Agent.Callbacks do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(cb, opts) do
    fields =
      Enum.reject(
        [
          on_response: InspectHelpers.fn_label(cb.on_response),
          on_tool_call: InspectHelpers.fn_label(cb.on_tool_call),
          on_error: InspectHelpers.fn_label(cb.on_error),
          on_max_steps: InspectHelpers.fn_label(cb.on_max_steps)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Agent.Callbacks<", to_doc(Map.new(fields), opts), ">"])
  end
end
