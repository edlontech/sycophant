defmodule Sycophant.Agent.State do
  @moduledoc """
  Internal state for the agent GenStateMachine process.
  """
  use TypedStruct

  alias Sycophant.Agent.Callbacks
  alias Sycophant.Agent.Stats
  alias Sycophant.Context
  alias Sycophant.Error

  typedstruct do
    field :model, String.t(), enforce: true
    field :context, Context.t(), default: %Context{}
    field :opts, keyword(), default: []
    field :callbacks, Callbacks.t(), default: %Callbacks{}
    field :stats, Stats.t(), default: %Stats{}
    field :from, {pid(), term()}
    field :last_error, term()
    field :current_step, non_neg_integer(), default: 0
    field :max_steps, pos_integer(), default: 10
    field :max_retries, non_neg_integer(), default: 3
    field :retry_count, non_neg_integer(), default: 0
    field :task_ref, reference()
    field :stream, function()
  end

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
