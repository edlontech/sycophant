import Config

config :sycophant, :wire_protocol_defaults, %{
  openrouter: "openai_responses",
  anthropic: "anthropic_messages",
  google: "google_gemini",
  amazon_bedrock: "bedrock_converse"
}

config :llm_db,
  allow: %{
    openai: ["*"],
    anthropic: ["*"],
    google: ["*"],
    amazon_bedrock: ["*"],
    openrouter: ["*"],
    azure: ["*"]
  }

import_config "#{config_env()}.exs"
