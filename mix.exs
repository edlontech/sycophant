defmodule Sycophant.MixProject do
  use Mix.Project

  def project do
    [
      app: :sycophant,
      description: description(),
      package: package(),
      version: "0.1.0",
      elixir: "~> 1.19",
      dialyzer: [
        plt_core_path: "_plts/core"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.post": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "test.recording": :test,
        "test.integration": :test
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "logo.png",
      extras: [
        {"README.md", title: "Overview"},
        {"guides/getting-started.md", title: "Getting Started"},
        {"guides/architecture.md", title: "Architecture"},
        {"guides/tool-use.md", title: "Tool Use"},
        {"guides/error-handling.md", title: "Error Handling"},
        {"guides/telemetry.md", title: "Telemetry"},
        {"guides/pricing.md", title: "Pricing and Cost Tracking"},
        {"guides/agent-mode.md", title: "Agent Mode"},
        {"guides/serialization.md", title: "Serialization"},
        {"guides/http-configuration.md", title: "HTTP Configuration"},
        {"guides/custom-providers.md", title: "Custom Providers"},
        {"guides/recording-tests.md", title: "Recording Tests"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "License"}
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/architecture.md",
          "guides/tool-use.md",
          "guides/error-handling.md",
          "guides/telemetry.md",
          "guides/pricing.md",
          "guides/agent-mode.md",
          "guides/serialization.md",
          "guides/http-configuration.md"
        ],
        "Extending Sycophant": [
          "guides/custom-providers.md",
          "guides/recording-tests.md"
        ]
      ],
      groups_for_modules: [
        "Client API": [
          Sycophant,
          Sycophant.Request,
          Sycophant.Response,
          Sycophant.Context,
          Sycophant.Message,
          Sycophant.Message.Content.Text,
          Sycophant.Message.Content.Image
        ],
        "Tools & Execution": [
          Sycophant.Tool,
          Sycophant.ToolCall,
          Sycophant.ToolExecutor
        ],
        Agent: [
          Sycophant.Agent,
          Sycophant.Agent.Callbacks,
          Sycophant.Agent.Stats,
          Sycophant.Agent.Stats.Turn,
          Sycophant.Agent.State,
          Sycophant.Agent.Telemetry
        ],
        Pipeline: [
          Sycophant.Pipeline,
          Sycophant.ModelResolver,
          Sycophant.ResponseValidator
        ],
        "Wire Protocols": [
          Sycophant.WireProtocol,
          Sycophant.WireProtocol.AnthropicMessages,
          Sycophant.WireProtocol.OpenAICompletions,
          Sycophant.WireProtocol.OpenAIResponses,
          Sycophant.WireProtocol.GoogleGemini,
          Sycophant.WireProtocol.BedrockConverse
        ],
        Embeddings: [
          Sycophant.EmbeddingPipeline,
          Sycophant.EmbeddingRequest,
          Sycophant.EmbeddingResponse,
          Sycophant.EmbeddingParams,
          Sycophant.EmbeddingWireProtocol,
          Sycophant.EmbeddingWireProtocol.OpenAIEmbed,
          Sycophant.EmbeddingWireProtocol.BedrockEmbed
        ],
        Authentication: [
          Sycophant.Auth,
          Sycophant.Auth.Bearer,
          Sycophant.Auth.Anthropic,
          Sycophant.Auth.Google,
          Sycophant.Auth.Bedrock,
          Sycophant.Auth.Azure
        ],
        "Telemetry & Observability": [
          Sycophant.Telemetry,
          Sycophant.OpenTelemetry
        ],
        Serialization: [
          Sycophant.Serializable,
          Sycophant.Serializable.Decoder
        ],
        Configuration: [
          Sycophant.Config,
          Sycophant.Credentials,
          Sycophant.ParamDefs
        ],
        "Data Types": [
          Sycophant.StreamChunk,
          Sycophant.Usage,
          Sycophant.Reasoning
        ],
        Errors: [
          Sycophant.Error,
          ~r/Sycophant\.Error\./
        ],
        Infrastructure: [
          Sycophant.Transport,
          Sycophant.Registry,
          Sycophant.Application,
          Sycophant.AWS.EventStream,
          Sycophant.Schema.JsonSchema
        ]
      ],
      nest_modules_by_prefix: [
        Sycophant.Error,
        Sycophant.Auth,
        Sycophant.Agent,
        Sycophant.WireProtocol,
        Sycophant.EmbeddingWireProtocol,
        Sycophant.Message.Content
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Sycophant.Application, []}
    ]
  end

  defp aliases do
    [
      "test.recording": ["test --include recording test/recording/"]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.8", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: :dev},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:gen_state_machine, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:llm_db, "~> 2026.3"},
      {:mimic, "~> 2.0", only: :test},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:opentelemetry_telemetry, "~> 1.1", optional: true},
      {:quiver, "~> 0.1", only: [:dev, :test]},
      {:recode, "~> 0.8", only: [:dev], runtime: false},
      {:splode, "~> 0.3"},
      {:telemetry, "~> 1.3"},
      {:tesla, "~> 1.16"},
      {:tesla_aws_sigv4, "~> 0.1"},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
      {:typedstruct, "~> 0.5"},
      {:zoi, "~> 0.11"},
      {:zoi_defstruct, "~> 0.2"}
    ]
  end

  defp description do
    "You are absolutely right if you use this lib!"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/edlontech/sycophant"},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
