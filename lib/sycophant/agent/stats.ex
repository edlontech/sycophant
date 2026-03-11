defmodule Sycophant.Agent.Stats do
  @moduledoc """
  Tracks token usage and cost across agent turns.
  """
  use TypedStruct

  defmodule Turn do
    @moduledoc """
    Usage snapshot for a single LLM call within an agent run.
    """
    use TypedStruct

    typedstruct do
      field :input_tokens, non_neg_integer(), default: 0
      field :output_tokens, non_neg_integer(), default: 0
      field :cost, float()
      field :timestamp, DateTime.t()
      field :finish_reason, atom()
    end
  end

  typedstruct do
    field :turns, [Turn.t()], default: []
    field :total_input_tokens, non_neg_integer(), default: 0
    field :total_output_tokens, non_neg_integer(), default: 0
    field :total_cost, float(), default: 0.0
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_turn(t(), Sycophant.Usage.t() | nil, atom()) :: t()
  def record_turn(stats, usage, finish_reason) do
    input = (usage && usage.input_tokens) || 0
    output = (usage && usage.output_tokens) || 0
    cost = (usage && usage.total_cost) || 0.0

    turn = %Turn{
      input_tokens: input,
      output_tokens: output,
      cost: cost,
      timestamp: DateTime.utc_now(),
      finish_reason: finish_reason
    }

    %{
      stats
      | turns: [turn | stats.turns],
        total_input_tokens: stats.total_input_tokens + input,
        total_output_tokens: stats.total_output_tokens + output,
        total_cost: stats.total_cost + cost
    }
  end

  @spec turns(t()) :: [Turn.t()]
  def turns(%__MODULE__{turns: turns}), do: Enum.reverse(turns)

  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{turns: turns}), do: length(turns)
end
