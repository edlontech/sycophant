import Config

config :sycophant, :wire_protocol_defaults, %{
  openrouter: "openai_responses",
  anthropic: "anthropic_messages",
  google: "google_gemini"
}

import_config "#{config_env()}.exs"
