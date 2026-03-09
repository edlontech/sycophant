defmodule Sycophant.Credentials do
  @moduledoc """
  Three-layer credential resolution: per-request > app config > env vars.

  Resolution order:
  1. Per-request credentials passed directly
  2. Application configuration under `:sycophant, :providers`
  3. Environment variables discovered via LLMDB provider metadata
  """

  alias Sycophant.Error

  @doc """
  Resolves credentials for the given provider using a three-layer strategy.

  Checks in order: (1) per-request credentials passed as `per_request_creds`,
  (2) application config under `:sycophant, :providers`, (3) environment
  variables discovered via LLMDB provider metadata. Returns the first non-empty
  result or a `MissingCredentials` error when all layers come up empty.
  """
  @spec resolve(atom(), map() | nil) :: {:ok, map()} | {:error, Splode.Error.t()}
  def resolve(provider, per_request_creds \\ nil)

  def resolve(_provider, creds) when is_map(creds) and map_size(creds) > 0 do
    {:ok, creds}
  end

  def resolve(provider, _) do
    with :error <- from_app_config(provider),
         :error <- from_env_vars(provider) do
      {:error, Error.Invalid.MissingCredentials.exception(provider: provider)}
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

  defp from_env_vars(provider) do
    case LLMDB.provider(provider) do
      {:ok, %{env: env_vars}} when is_list(env_vars) and env_vars != [] ->
        resolve_env_vars(env_vars)

      _ ->
        :error
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

  defp env_key_to_atom(var) do
    var
    |> String.downcase()
    |> String.replace(~r/^[a-z]+_/, "")
    |> String.to_atom()
  end
end
