import Config

config :sycophant, :tesla,
  adapter: {Tesla.Adapter.Quiver, name: Sycophant.Quiver},
  middlewares: [{Sycophant.Tesla.RecorderMiddleware, []}]

config :sycophant, :test_models, [
  "openai:gpt-4o-mini",
  "openai:gpt-3.5-turbo"
]

config :sycophant, :structured_output_models, [
  "openai:gpt-4o-mini"
]
