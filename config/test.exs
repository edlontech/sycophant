import Config

config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Quiver, name: Sycophant.Quiver, receive_timeout: 60_000},
  middlewares: [{Sycophant.Tesla.RecorderMiddleware, []}]

config :sycophant, :test_models, [
  %{model: "openai:gpt-3.5-turbo", structured_output: false},
  %{model: "openai:gpt-4o-mini", structured_output: true},
  %{model: "openai:gpt-5.2", structured_output: true},
  %{model: "openai:gpt-5-nano", structured_output: true, reasoning: true},
  %{model: "openrouter:openai/gpt-4o-mini", structured_output: true},
  %{model: "openrouter:anthropic/claude-haiku-4.5", structured_output: true},
  %{model: "openrouter:google/gemini-2.5-flash", structured_output: true},
  %{model: "openrouter:deepseek/deepseek-r1", structured_output: false},
  %{model: "anthropic:claude-haiku-4-5-20251001", structured_output: true, reasoning: true},
  %{model: "google:gemini-2.5-flash", structured_output: true, reasoning: true},
  %{model: "google:gemini-3.1-flash-lite-preview", structured_output: true, reasoning: true},
  %{
    model: "amazon_bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0",
    structured_output: true,
    reasoning: true
  }
]

config :sycophant, :test_embedding_models, [
  %{model: "amazon_bedrock:cohere.embed-v4"}
]
