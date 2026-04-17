defmodule Sycophant.Agent.State do
  @moduledoc """
  Internal state for the agent GenStateMachine process.
  """
  alias Sycophant.Agent.Callbacks
  alias Sycophant.Agent.Stats
  alias Sycophant.Context
  alias Sycophant.Error

  @enforce_keys [:model]
  defstruct [
    :model,
    :from,
    :last_error,
    :task_ref,
    :stream,
    context: %Context{},
    opts: [],
    callbacks: %Callbacks{},
    stats: %Stats{},
    current_step: 0,
    max_steps: 10,
    max_retries: 3,
    retry_count: 0
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          context: Context.t(),
          opts: keyword(),
          callbacks: Callbacks.t(),
          stats: Stats.t(),
          from: {pid(), term()} | nil,
          last_error: term() | nil,
          current_step: non_neg_integer(),
          max_steps: pos_integer(),
          max_retries: non_neg_integer(),
          retry_count: non_neg_integer(),
          task_ref: reference() | nil,
          stream: (term() -> term()) | {term(), (term(), term() -> term())} | nil
        }

  @doc "Creates a new State from keyword options, requiring `:model`."
  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        {:error, Error.Invalid.MissingModel.exception([])}

      model ->
        {:ok,
         %__MODULE__{
           model: model,
           context: Keyword.get(opts, :context, %Context{}),
           opts: Keyword.get(opts, :opts, []),
           callbacks: Keyword.get(opts, :callbacks, %Callbacks{}),
           stats: Keyword.get(opts, :stats, %Stats{}),
           max_steps: Keyword.get(opts, :max_steps, 10),
           max_retries: Keyword.get(opts, :max_retries, 3),
           stream: Keyword.get(opts, :stream)
         }}
    end
  end
end

defimpl Inspect, for: Sycophant.Agent.State do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(state, opts) do
    fields =
      Enum.reject(
        [
          model: state.model,
          step: "#{state.current_step}/#{state.max_steps}",
          retries: "#{state.retry_count}/#{state.max_retries}",
          stream: InspectHelpers.fn_label(state.stream)
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Agent.State<", to_doc(Map.new(fields), opts), ">"])
  end
end
