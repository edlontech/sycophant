defmodule Sycophant.Config do
  @moduledoc """
  Centralized configuration for Sycophant with schema validation.

  Configuration is read from the `:sycophant` application environment
  and validated through Zoi schemas.

  ## Provider Credentials

      # config/runtime.exs
      config :sycophant, :providers,
        openai: [api_key: System.get_env("OPENAI_API_KEY")],
        anthropic: [api_key: System.get_env("ANTHROPIC_API_KEY")],
        amazon_bedrock: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        azure: [
          api_key: System.get_env("AZURE_API_KEY"),
          base_url: "https://my-resource.openai.azure.com",
          deployment_name: "gpt-4o",
          api_version: "2025-04-01-preview"
        ]

  ## Tesla HTTP Client

      config :sycophant, :tesla,
        adapter: Tesla.Adapter.Mint,
        middlewares: [Tesla.Middleware.Logger]
  """

  defmodule Provider do
    @moduledoc "Schema for provider-specific credentials."
    use ZoiDefstruct

    defstruct api_key: Zoi.optional(Zoi.string()),
              api_secret: Zoi.optional(Zoi.string()),
              region: Zoi.optional(Zoi.string()),
              access_key_id: Zoi.optional(Zoi.string()),
              secret_access_key: Zoi.optional(Zoi.string()),
              base_url: Zoi.optional(Zoi.string()),
              deployment_name: Zoi.optional(Zoi.string()),
              api_version: Zoi.optional(Zoi.string())
  end

  defmodule Tesla do
    @moduledoc "Schema for Tesla HTTP client configuration."
    use ZoiDefstruct

    defstruct adapter: Zoi.optional(Zoi.any()),
              middlewares: Zoi.list(Zoi.any()) |> Zoi.default([])
  end

  @doc """
  Fetches and validates the configuration for the given provider name.

  Reads the `:providers` key from the `:sycophant` application environment,
  extracts the entry matching `name`, and parses it through the `Provider`
  Zoi schema.

  ## Examples

      Application.put_env(:sycophant, :providers, openai: [api_key: "sk-test"])
      {:ok, config} = Sycophant.Config.provider(:openai)
      config.api_key
      #=> "sk-test"
  """
  @spec provider(atom()) :: {:ok, Provider.t()} | {:error, [Zoi.Error.t()]}
  def provider(name) do
    Application.get_env(:sycophant, :providers, [])
    |> Keyword.get(name, [])
    |> Map.new()
    |> then(&Zoi.parse(Provider.t(), &1))
  end

  @doc """
  Returns the wire protocol defaults map from application config.

  Used by `ModelResolver` to fall back to a configured wire protocol
  when LLMDB metadata doesn't specify one for a provider. Each provider
  maps to a nested map keyed by kind (`:chat`, `:embedding`, etc.).
  """
  @wire_protocol_defaults %{
    openrouter: %{chat: :openai_responses},
    openai: %{embedding: :openai_embed},
    anthropic: %{chat: :anthropic_messages},
    google: %{chat: :google_gemini},
    amazon_bedrock: %{chat: :bedrock_converse, embedding: :bedrock_embed},
    azure: %{embedding: :openai_embed}
  }

  @spec wire_protocol_defaults() :: map()
  def wire_protocol_defaults do
    Application.get_env(:sycophant, :wire_protocol_defaults, @wire_protocol_defaults)
  end

  @doc """
  Fetches and validates the Tesla HTTP client configuration.

  Reads the `:tesla` key from the `:sycophant` application environment and
  parses it through the `Tesla` Zoi schema. The returned struct contains the
  adapter module and any additional middlewares to inject into every request.

  ## Examples

      Application.put_env(:sycophant, :tesla, adapter: Tesla.Adapter.Mint)
      {:ok, config} = Sycophant.Config.tesla()
      config.adapter
      #=> Tesla.Adapter.Mint
  """
  @spec tesla() :: {:ok, Tesla.t()} | {:error, [Zoi.Error.t()]}
  def tesla do
    Application.get_env(:sycophant, :tesla, [])
    |> Map.new()
    |> then(&Zoi.parse(Tesla.t(), &1))
  end
end

defimpl Inspect, for: Sycophant.Config.Provider do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(provider, opts) do
    fields =
      Enum.reject(
        [
          api_key: InspectHelpers.redact(provider.api_key),
          api_secret: InspectHelpers.redact(provider.api_secret),
          access_key_id: InspectHelpers.redact(provider.access_key_id),
          secret_access_key: InspectHelpers.redact(provider.secret_access_key),
          region: provider.region,
          base_url: provider.base_url,
          deployment_name: provider.deployment_name,
          api_version: provider.api_version
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Config.Provider<", to_doc(Map.new(fields), opts), ">"])
  end
end
