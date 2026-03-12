defmodule Sycophant.Application do
  @moduledoc false

  use Application

  @doc false
  @impl true
  def start(_type, _args) do
    Sycophant.Registry.init()

    children = quiver_children() ++ dev_children()

    opts = [strategy: :one_for_one, name: Sycophant.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp quiver_children do
    if Code.ensure_loaded?(Quiver.Supervisor) do
      [{Quiver.Supervisor, name: Sycophant.Quiver, pools: %{default: [size: 10]}}]
    else
      []
    end
  end

  defp dev_children do
    if top_level_project?() and System.get_env("TIDEWAVE_REPL") == "true" and
         Code.ensure_loaded?(Bandit) do
      Application.ensure_all_started(:tidewave)
      port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
      [{Bandit, plug: Tidewave, port: port}]
    else
      []
    end
  end

  defp top_level_project? do
    Code.ensure_loaded?(Mix.Project) and apply(Mix.Project, :get, []) == Sycophant.MixProject
  end
end
