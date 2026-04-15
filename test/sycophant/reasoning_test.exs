defmodule Sycophant.ReasoningTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message.Content.Thinking
  alias Sycophant.Reasoning

  describe "struct" do
    test "creates with content and encrypted_content" do
      reasoning = %Reasoning{
        content: [%Thinking{text: "step 1"}, %Thinking{text: "step 2"}],
        encrypted_content: "encrypted_blob_here"
      }

      assert [%Thinking{text: "step 1"}, %Thinking{text: "step 2"}] = reasoning.content
      assert reasoning.encrypted_content == "encrypted_blob_here"
    end

    test "creates with thinking that has summary" do
      reasoning = %Reasoning{
        content: [%Thinking{summary: "concise summary"}]
      }

      assert [%Thinking{summary: "concise summary", text: nil}] = reasoning.content
    end

    test "creates with defaults" do
      reasoning = %Reasoning{}
      assert reasoning.content == []
      assert reasoning.encrypted_content == nil
    end
  end
end
