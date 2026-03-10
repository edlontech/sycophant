defmodule Sycophant.MixProject do
  use Mix.Project

  def project do
    [
      app: :sycophant,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      {:jason, "~> 1.4"},
      {:llm_db, github: "ycastorium/llm_db", branch: "provider_and_wire_improvements"},
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
end
