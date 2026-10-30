defmodule Sycophant.Application do
  @moduledoc false

  use Application

  @doc false
  @impl true
  def start(_type, _args) do
    load_llmdb()
    Sycophant.Registry.init()

    children =
      quiver_children() ++
        [Sycophant.Auth.GithubCopilot.TokenCache] ++
        dev_children()

    opts = [strategy: :one_for_one, name: Sycophant.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Loads the full catalog by default. Support is decided per model at
  # resolution time, based on whether a registered wire protocol exists.
  defp load_llmdb do
    LLMDB.load(allow: Application.get_env(:sycophant, :llmdb_allow, :all))
  end

  defp quiver_children do
    if Code.ensure_loaded?(Quiver.Supervisor) do
      [{Quiver.Supervisor, name: Sycophant.Quiver, pools: %{default: [size: 10]}}]
    else
      []
    end
  end

  if Mix.env() == :dev do
    defp dev_children do
      if System.get_env("TIDEWAVE_REPL") == "true" and Code.ensure_loaded?(Bandit) do
        ensure_tidewave_started()
        port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
        [{Bandit, plug: Tidewave, port: port}]
      else
        []
      end
    end

    defp ensure_tidewave_started do
      case Application.ensure_all_started(:tidewave) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  else
    defp dev_children, do: []
  end
end
