defmodule Sycophant.Credentials do
  @moduledoc """
  Three-layer credential resolution for LLM providers.

  Credentials are resolved in order of specificity:

  1. **Per-request** -- credentials passed directly in options
  2. **Application config** -- from `config :sycophant, :providers`
  3. **Environment variables** -- discovered via LLMDB provider metadata

  The first non-empty layer wins. If all layers are empty, providers with
  `extra: %{auth: :none}` or `extra: %{auth: :optional}` in their LLMDB
  metadata receive an empty credential map, while all other providers raise
  a `MissingCredentials` error.

  ## Examples

      # Per-request credentials take priority
      Sycophant.generate_text("openai:gpt-4o-mini", messages,
        credentials: %{api_key: "sk-override"}
      )

      # Falls back to app config, then env vars
      Sycophant.generate_text("openai:gpt-4o-mini", messages)

      # Local providers with auth: :none skip credentials entirely
      Sycophant.generate_text("ollama:llama3", messages)
  """

  alias Sycophant.Error.Invalid.MissingCredentials

  @doc """
  Resolves credentials for the given provider using a three-layer strategy.

  Checks in order: (1) per-request credentials passed as `per_request_creds`,
  (2) application config under `:sycophant, :providers`, (3) environment
  variables discovered via LLMDB provider metadata. Returns the first non-empty
  result. When all layers come up empty, returns an empty map for providers
  with `auth: :none` or `auth: :optional` in LLMDB, or a `MissingCredentials`
  error otherwise.
  """
  @spec resolve(atom(), map() | nil) :: {:ok, map()} | {:error, Splode.Error.t()}
  def resolve(provider, per_request_creds \\ nil)

  def resolve(_provider, creds) when is_map(creds) and map_size(creds) > 0 do
    {:ok, creds}
  end

  def resolve(provider, _) do
    with :error <- from_app_config(provider),
         {:error, llmdb_provider} <- from_llmdb(provider) do
      if auth_optional?(llmdb_provider) do
        {:ok, %{}}
      else
        {:error, MissingCredentials.exception(provider: provider)}
      end
    end
  end

  defp from_app_config(provider) do
    case Sycophant.Config.provider(provider) do
      {:ok, config} ->
        creds = config |> Map.from_struct() |> Map.reject(fn {_, v} -> is_nil(v) end)
        if map_size(creds) > 0, do: {:ok, creds}, else: :error

      {:error, _} ->
        :error
    end
  end

  defp from_llmdb(provider) do
    case LLMDB.provider(provider) do
      {:ok, %{env: env_vars} = llmdb_provider}
      when is_list(env_vars) and env_vars != [] ->
        case resolve_env_vars(env_vars) do
          {:ok, _} = ok -> ok
          :error -> {:error, llmdb_provider}
        end

      {:ok, llmdb_provider} ->
        {:error, llmdb_provider}

      {:error, _} ->
        {:error, nil}
    end
  end

  defp resolve_env_vars(env_vars) do
    resolved =
      env_vars
      |> Enum.map(fn var -> {env_key_to_atom(var), System.get_env(var)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(resolved) > 0, do: {:ok, resolved}, else: :error
  end

  defp auth_optional?(%{extra: %{auth: auth}}) when auth in [:none, :optional], do: true
  defp auth_optional?(_), do: false

  defp env_key_to_atom(var) do
    var
    |> String.downcase()
    |> String.replace(~r/^[a-z]+_/, "")
    |> String.to_atom()
  end
end
