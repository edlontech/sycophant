defmodule Sycophant.Recording.PromptCacheTest do
  @models Sycophant.RecordingCase.test_models(require: :prompt_cache)
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Context
  alias Sycophant.Message

  # Roughly 6k tokens: above the largest provider minimum (4096 for Claude Haiku 4.5).
  @system_prompt Enum.map_join(1..300, "\n", fn i ->
                   "Rule #{i}: when the user mentions topic #{i}, answer politely, " <>
                     "cite rule #{i}, and keep the reply under #{i + 10} words."
                 end)

  @tag recording_prefix: true
  test "reads the cached prompt prefix on the second turn", %{model: model} do
    opts = recording_opts(cache_key: "sycophant-recording-prompt-cache")

    messages = [Message.system(@system_prompt), Message.user("Reply with OK.")]
    assert {:ok, resp1} = Sycophant.generate_text(model, messages, opts)

    ctx = Context.add(resp1.context, Message.user("Reply with OK again."))
    assert {:ok, resp2} = Sycophant.generate_text(model, ctx, opts)

    assert resp2.usage.cache_read_input_tokens > 0
  end
end
