defmodule Sycophant.InspectHelpersTest do
  use ExUnit.Case, async: true

  alias Sycophant.InspectHelpers

  describe "truncate/2" do
    test "returns nil for nil" do
      assert InspectHelpers.truncate(nil) == nil
    end

    test "returns short strings unchanged" do
      assert InspectHelpers.truncate("hello") == "hello"
    end

    test "truncates long strings with ellipsis" do
      long = String.duplicate("a", 60)
      result = InspectHelpers.truncate(long)
      assert String.length(result) == 53
      assert String.ends_with?(result, "...")
    end

    test "respects custom limit" do
      assert InspectHelpers.truncate("hello world", 5) == "hello..."
    end
  end

  describe "truncate_inspect/2" do
    test "returns nil for nil" do
      assert InspectHelpers.truncate_inspect(nil) == nil
    end

    test "inspects and truncates terms" do
      map = Map.new(1..20, &{:"key_#{&1}", &1})
      result = InspectHelpers.truncate_inspect(map)
      assert String.ends_with?(result, "...")
    end
  end

  describe "redact/1" do
    test "returns nil for nil" do
      assert InspectHelpers.redact(nil) == nil
    end

    test "returns redacted for any value" do
      assert InspectHelpers.redact("secret") == "**REDACTED**"
      assert InspectHelpers.redact(123) == "**REDACTED**"
    end
  end

  describe "fn_label/1" do
    test "returns nil for nil" do
      assert InspectHelpers.fn_label(nil) == nil
    end

    test "returns arity label for functions" do
      assert InspectHelpers.fn_label(fn -> :ok end) == "fn/0"
      assert InspectHelpers.fn_label(fn _x -> :ok end) == "fn/1"
      assert InspectHelpers.fn_label(&Enum.map/2) == "fn/2"
    end
  end
end
