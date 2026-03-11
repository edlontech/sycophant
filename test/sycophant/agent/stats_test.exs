defmodule Sycophant.Agent.StatsTest do
  use ExUnit.Case, async: true

  alias Sycophant.Agent.Stats
  alias Sycophant.Usage

  test "new/0 starts with zero counters" do
    stats = Stats.new()
    assert stats.total_input_tokens == 0
    assert stats.total_output_tokens == 0
    assert stats.turns == []
  end

  test "record_turn/3 accumulates token counts" do
    usage = %Usage{input_tokens: 100, output_tokens: 50, total_cost: 0.001}
    stats = Stats.record_turn(Stats.new(), usage, :stop)
    assert stats.total_input_tokens == 100
    assert stats.total_output_tokens == 50
    assert stats.total_cost == 0.001
    assert [%Stats.Turn{input_tokens: 100, finish_reason: :stop}] = stats.turns
  end

  test "record_turn/3 handles nil usage" do
    stats = Stats.record_turn(Stats.new(), nil, :stop)
    assert stats.total_input_tokens == 0
    assert Stats.turn_count(stats) == 1
  end

  test "record_turn/3 accumulates across multiple turns" do
    usage1 = %Usage{input_tokens: 100, output_tokens: 50, total_cost: 0.001}
    usage2 = %Usage{input_tokens: 200, output_tokens: 100, total_cost: 0.002}

    stats =
      Stats.new()
      |> Stats.record_turn(usage1, :stop)
      |> Stats.record_turn(usage2, :tool_use)

    assert stats.total_input_tokens == 300
    assert stats.total_output_tokens == 150
    assert stats.total_cost == 0.003
    assert Stats.turn_count(stats) == 2
  end

  test "turns/1 returns turns in chronological order" do
    usage1 = %Usage{input_tokens: 10, output_tokens: 5, total_cost: 0.001}
    usage2 = %Usage{input_tokens: 20, output_tokens: 10, total_cost: 0.002}

    stats =
      Stats.new()
      |> Stats.record_turn(usage1, :stop)
      |> Stats.record_turn(usage2, :tool_use)

    turns = Stats.turns(stats)
    assert [%Stats.Turn{finish_reason: :stop}, %Stats.Turn{finish_reason: :tool_use}] = turns
  end

  test "record_turn/3 stores consistent cost on turn (nil when usage nil)" do
    stats = Stats.record_turn(Stats.new(), nil, :stop)
    [turn] = Stats.turns(stats)
    assert turn.cost == 0.0
  end
end
