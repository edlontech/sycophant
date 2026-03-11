defmodule Sycophant.Agent.StateTest do
  use ExUnit.Case, async: true

  alias Sycophant.Agent.Callbacks
  alias Sycophant.Agent.State
  alias Sycophant.Agent.Stats
  alias Sycophant.Context
  alias Sycophant.Error

  test "new/1 returns MissingModel error when model is nil" do
    assert {:error, %Error.Invalid.MissingModel{}} = State.new(model: nil)
  end

  test "new/1 returns MissingModel error when model is omitted" do
    assert {:error, %Error.Invalid.MissingModel{}} = State.new([])
  end

  test "new/1 returns state with defaults" do
    assert {:ok, state} = State.new(model: "anthropic:claude-haiku-4-5-20251001")
    assert state.model == "anthropic:claude-haiku-4-5-20251001"
    assert %Context{} = state.context
    assert state.opts == []
    assert %Callbacks{} = state.callbacks
    assert %Stats{} = state.stats
    assert is_nil(state.from)
    assert is_nil(state.last_error)
    assert state.current_step == 0
    assert state.max_steps == 10
    assert is_nil(state.task_ref)
  end
end
