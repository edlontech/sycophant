defmodule Sycophant.DoctestsTest do
  use ExUnit.Case, async: true

  doctest Sycophant.Message
  doctest Sycophant.Message.Content.Text
  doctest Sycophant.ToolCall
  doctest Sycophant.Usage
  doctest Sycophant.Reasoning
end
