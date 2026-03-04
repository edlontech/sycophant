defmodule Sycophant.ReasoningTest do
  use ExUnit.Case, async: true

  alias Sycophant.Reasoning

  describe "struct" do
    test "creates with all fields" do
      reasoning = %Reasoning{
        summary: "The user asked about weather",
        encrypted_content: "encrypted_blob_here"
      }

      assert reasoning.summary == "The user asked about weather"
      assert reasoning.encrypted_content == "encrypted_blob_here"
    end

    test "creates with summary only" do
      reasoning = %Reasoning{summary: "Thinking about the answer"}
      assert reasoning.summary == "Thinking about the answer"
      assert reasoning.encrypted_content == nil
    end

    test "creates with all nil fields" do
      reasoning = %Reasoning{}
      assert reasoning.summary == nil
      assert reasoning.encrypted_content == nil
    end
  end
end
