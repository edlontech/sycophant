defmodule Sycophant.Agent.Stats do
  @moduledoc """
  Tracks token usage and cost across agent turns.
  """
  defmodule Turn do
    @moduledoc """
    Usage snapshot for a single LLM call within an agent run.
    """
    defstruct [
      :cost,
      :timestamp,
      :finish_reason,
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0
    ]

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            reasoning_tokens: non_neg_integer(),
            cost: float() | nil,
            timestamp: DateTime.t() | nil,
            finish_reason: atom() | nil
          }
  end

  defstruct turns: [],
            total_input_tokens: 0,
            total_output_tokens: 0,
            total_reasoning_tokens: 0,
            total_cost: 0.0

  @type t :: %__MODULE__{
          turns: [Turn.t()],
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          total_reasoning_tokens: non_neg_integer(),
          total_cost: float()
        }

  @doc "Creates a new empty Stats."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records a completed turn with usage data and finish reason."
  @spec record_turn(t(), Sycophant.Usage.t() | nil, atom()) :: t()
  def record_turn(stats, usage, finish_reason) do
    input = (usage && usage.input_tokens) || 0
    output = (usage && usage.output_tokens) || 0
    reasoning = (usage && usage.reasoning_tokens) || 0
    cost = (usage && usage.total_cost) || 0.0

    turn = %Turn{
      input_tokens: input,
      output_tokens: output,
      reasoning_tokens: reasoning,
      cost: cost,
      timestamp: DateTime.utc_now(),
      finish_reason: finish_reason
    }

    %{
      stats
      | turns: [turn | stats.turns],
        total_input_tokens: stats.total_input_tokens + input,
        total_output_tokens: stats.total_output_tokens + output,
        total_reasoning_tokens: stats.total_reasoning_tokens + reasoning,
        total_cost: stats.total_cost + cost
    }
  end

  @doc "Returns turns in chronological order."
  @spec turns(t()) :: [Turn.t()]
  def turns(%__MODULE__{turns: turns}), do: Enum.reverse(turns)

  @doc "Returns the number of recorded turns."
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{turns: turns}), do: length(turns)
end

defimpl Inspect, for: Sycophant.Agent.Stats.Turn do
  import Inspect.Algebra

  def inspect(turn, opts) do
    fields =
      Enum.reject(
        [
          in: turn.input_tokens,
          out: turn.output_tokens,
          reasoning: turn.reasoning_tokens,
          cost: turn.cost,
          finish_reason: turn.finish_reason
        ],
        fn {_, v} -> is_nil(v) or v == 0 end
      )

    concat(["#Sycophant.Agent.Stats.Turn<", to_doc(Map.new(fields), opts), ">"])
  end
end

defimpl Inspect, for: Sycophant.Agent.Stats do
  import Inspect.Algebra

  def inspect(stats, opts) do
    fields = %{
      turns: length(stats.turns),
      tokens: "#{stats.total_input_tokens}+#{stats.total_output_tokens}",
      cost: stats.total_cost
    }

    fields =
      if stats.total_reasoning_tokens > 0,
        do: Map.put(fields, :reasoning, stats.total_reasoning_tokens),
        else: fields

    concat(["#Sycophant.Agent.Stats<", to_doc(fields, opts), ">"])
  end
end
