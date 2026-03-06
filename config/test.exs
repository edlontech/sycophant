import Config

config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Quiver, name: Sycophant.Quiver},
  middlewares: [{Sycophant.Tesla.RecorderMiddleware, []}]

config :sycophant, :test_models, [
  %{model: "openai:gpt-4o-mini", structured_output: true},
  %{model: "openai:gpt-3.5-turbo", structured_output: false},
  %{model: "openrouter:openai/gpt-4o-mini", structured_output: true},
  %{model: "openrouter:anthropic/claude-haiku-4.5", structured_output: true},
  %{model: "openrouter:google/gemini-2.5-flash", structured_output: true},
  %{model: "openrouter:deepseek/deepseek-r1", structured_output: false},
  %{model: "anthropic:claude-haiku-4-5-20251001", structured_output: true},
  %{model: "google:gemini-2.5-flash", structured_output: true},
  %{model: "amazon_bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0", structured_output: true}
]
