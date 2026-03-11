defmodule Sycophant.Agent.CallbacksTest do
  use ExUnit.Case, async: true

  alias Sycophant.Agent.Callbacks

  test "new/0 creates struct with nil callbacks" do
    cb = Callbacks.new()
    assert is_nil(cb.on_response)
    assert is_nil(cb.on_tool_call)
    assert is_nil(cb.on_error)
    assert is_nil(cb.on_max_steps)
  end

  test "new/1 accepts callback functions" do
    cb = Callbacks.new(on_response: &Function.identity/1)
    assert is_function(cb.on_response, 1)
  end
end
