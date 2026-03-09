defmodule Sycophant.Config do
  @moduledoc """
  Centralized configuration for Sycophant with schema validation.

  Configuration is read from the `:sycophant` application environment
  and validated through Zoi schemas.

  ## Example

      Application.put_env(:sycophant, :providers, openai: [api_key: "sk-..."])
      Application.put_env(:sycophant, :tesla, adapter: Tesla.Adapter.Mint, middlewares: [])
  """

  defmodule Provider do
    @moduledoc "Schema for provider-specific credentials."
    use ZoiDefstruct

    defstruct api_key: Zoi.optional(Zoi.string()),
              api_secret: Zoi.optional(Zoi.string()),
              region: Zoi.optional(Zoi.string()),
              access_key_id: Zoi.optional(Zoi.string()),
              secret_access_key: Zoi.optional(Zoi.string())
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
  Zoi schema. Returns `{:ok, %Provider{}}` or `{:error, errors}` when
  validation fails.
  """
  @spec provider(atom()) :: {:ok, Provider.t()} | {:error, [Zoi.Error.t()]}
  def provider(name) do
    Application.get_env(:sycophant, :providers, [])
    |> Keyword.get(name, [])
    |> Map.new()
    |> then(&Zoi.parse(Provider.t(), &1))
  end

  @doc """
  Fetches and validates the Tesla HTTP client configuration.

  Reads the `:tesla` key from the `:sycophant` application environment and
  parses it through the `Tesla` Zoi schema. The returned struct contains the
  adapter module and any additional middlewares to inject into every request.
  """
  @spec tesla() :: {:ok, Tesla.t()} | {:error, [Zoi.Error.t()]}
  def tesla do
    Application.get_env(:sycophant, :tesla, [])
    |> Map.new()
    |> then(&Zoi.parse(Tesla.t(), &1))
  end
end
