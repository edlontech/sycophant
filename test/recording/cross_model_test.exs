defmodule Sycophant.Recording.CrossModelTest do
  use Sycophant.RecordingCase, async: true

  alias Sycophant.Context
  alias Sycophant.Message
  alias Sycophant.Response

  @anthropic "anthropic:claude-haiku-4-5-20251001"
  @openai "openai:gpt-5-nano"
  @gemini "google:gemini-2.5-flash"

  defp weather_tool(opts \\ []) do
    %Sycophant.Tool{
      name: "get_weather",
      description: "Get current weather for a city. Returns temperature and conditions.",
      parameters: Zoi.map(%{city: Zoi.string()}),
      function:
        if(Keyword.get(opts, :auto, true), do: fn %{city: city} -> "#{city}: 18C, cloudy" end)
    }
  end

  defp ask(context_or_messages, question) do
    case context_or_messages do
      %Context{} = ctx -> Context.add(ctx, Message.user(question))
      messages -> messages ++ [Message.user(question)]
    end
  end

  defp generate(model, input, tool) do
    Sycophant.generate_text(model, input, recording_opts(tools: [tool], reasoning_effort: :low))
  end

  defp assistant_providers(%Response{} = response) do
    for %Message{role: :assistant, provider: provider} <- Response.messages(response),
        do: provider
  end

  defp tool_call_ids(%Response{} = response) do
    for %Message{role: :assistant, tool_calls: [_ | _] = tcs} <- Response.messages(response),
        tc <- tcs,
        do: tc.id
  end

  @start [
    Message.system("You are a helpful assistant. Be concise."),
    Message.user(
      "What's the weather in Paris? You must call the get_weather tool with city=\"Paris\"."
    )
  ]

  @tag recording: "cross_model/anthropic_to_openai_responses"
  test "continues an Anthropic conversation on OpenAI Responses" do
    {:ok, resp_a} = generate(@anthropic, @start, weather_tool())
    assert :anthropic in assistant_providers(resp_a)

    {:ok, resp_b} =
      generate(@openai, ask(resp_a.context, "Should I bring an umbrella?"), weather_tool())

    assert is_binary(resp_b.text)
    assert :anthropic in assistant_providers(resp_b)
    assert List.last(assistant_providers(resp_b)) == :openai
  end

  @tag recording: "cross_model/openai_responses_to_anthropic_mid_tool_loop"
  test "continues an OpenAI tool loop on Anthropic right after the tool result" do
    {:ok, resp_a} = generate(@openai, @start, weather_tool(auto: false))
    assert [_ | _] = resp_a.tool_calls

    results = Enum.map(resp_a.tool_calls, &Message.tool_result(&1, "Paris: 18C, cloudy"))

    {:ok, resp_b} = generate(@anthropic, Context.add(resp_a.context, results), weather_tool())

    assert is_binary(resp_b.text)
    assert :openai in assistant_providers(resp_b)
    assert List.last(assistant_providers(resp_b)) == :anthropic
  end

  @tag recording: "cross_model/gemini_to_anthropic"
  test "continues a Gemini conversation with repeated tool call ids on Anthropic" do
    {:ok, resp_a1} = generate(@gemini, @start, weather_tool())

    {:ok, resp_a2} =
      generate(
        @gemini,
        ask(
          resp_a1.context,
          "And in London? You must call the get_weather tool with city=\"London\"."
        ),
        weather_tool()
      )

    assert :google in assistant_providers(resp_a2)
    ids = tool_call_ids(resp_a2)
    assert length(ids) > length(Enum.uniq(ids)), "expected Gemini to repeat tool call ids"

    {:ok, resp_b} =
      generate(@anthropic, ask(resp_a2.context, "Which city is warmer?"), weather_tool())

    assert is_binary(resp_b.text)
    assert :google in assistant_providers(resp_b)
    assert List.last(assistant_providers(resp_b)) == :anthropic
  end
end
