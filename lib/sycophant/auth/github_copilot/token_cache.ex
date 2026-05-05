defmodule Sycophant.Auth.GithubCopilot.TokenCache do
  @moduledoc """
  Supervised GenServer that caches Copilot tokens per `{github_host, sha256(gh_token)}`.

  - Lazily refreshes on `fetch/2` when within 30s of `expires_at`.
  - Serializes concurrent refreshes per cache key (no thundering herd).
  - 32-entry LRU keeps memory bounded.
  - State has a custom `Inspect` impl that redacts `copilot_token`.

  Public API: `fetch/2`. All other functions are GenServer internals.
  """

  use GenServer
  require Logger

  alias Sycophant.Auth.GithubCopilot.Exchange

  @max_entries 32
  @refresh_buffer_seconds 30

  defmodule Entry do
    @moduledoc false
    @derive {Inspect, only: [:expires_at, :endpoints, :fetched_at]}
    defstruct [:copilot_token, :expires_at, :endpoints, :fetched_at]

    @type t :: %__MODULE__{
            copilot_token: String.t(),
            expires_at: DateTime.t(),
            endpoints: map(),
            fetched_at: DateTime.t()
          }
  end

  defmodule State do
    @moduledoc false
    @derive {Inspect, only: [:refreshing]}
    defstruct entries: %{}, refreshing: %{}

    @type cache_key :: {String.t(), binary()}
    @type t :: %__MODULE__{
            entries: %{optional(cache_key) => Sycophant.Auth.GithubCopilot.TokenCache.Entry.t()},
            refreshing: %{optional(cache_key) => [GenServer.from()]}
          }
  end

  @doc "Starts the token cache. Called by Sycophant.Application."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %State{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns a valid Copilot token entry for the given GitHub credential.

  Blocks until either a cached entry is available or a fresh exchange completes.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, Splode.Error.t()}
  def fetch(github_host, github_token) do
    GenServer.call(__MODULE__, {:fetch, github_host, github_token}, 30_000)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, github_host, github_token}, from, state) do
    cache_key = {github_host, :crypto.hash(:sha256, github_token)}

    cond do
      live_entry?(state.entries[cache_key]) ->
        {:reply, {:ok, state.entries[cache_key]}, state}

      refresh_in_flight?(state.refreshing, cache_key) ->
        state = enqueue_waiter(state, cache_key, from)
        {:noreply, state}

      true ->
        state = enqueue_waiter(state, cache_key, from)
        spawn_refresh(github_host, github_token, cache_key)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:refresh_done, cache_key, result}, state) do
    waiters = Map.get(state.refreshing, cache_key, [])

    state = %{state | refreshing: Map.delete(state.refreshing, cache_key)}

    state =
      case result do
        {:ok, entry} ->
          %{state | entries: insert_with_lru(state.entries, cache_key, entry)}

        {:error, _} ->
          state
      end

    Enum.each(waiters, fn from -> GenServer.reply(from, result) end)

    {:noreply, state}
  end

  defp live_entry?(nil), do: false

  defp live_entry?(%Entry{expires_at: expires_at}) do
    threshold = DateTime.add(DateTime.utc_now(), @refresh_buffer_seconds, :second)
    DateTime.compare(threshold, expires_at) == :lt
  end

  defp refresh_in_flight?(refreshing, cache_key),
    do: Map.has_key?(refreshing, cache_key)

  defp enqueue_waiter(state, cache_key, from) do
    waiters = Map.get(state.refreshing, cache_key, [])
    %{state | refreshing: Map.put(state.refreshing, cache_key, [from | waiters])}
  end

  defp spawn_refresh(github_host, github_token, cache_key) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          case Exchange.exchange(github_host, github_token) do
            {:ok, entry_map} ->
              {:ok, struct(Entry, entry_map)}

            {:error, _} = err ->
              err
          end
        rescue
          exception ->
            {:error,
             Sycophant.Error.Provider.ServerError.exception(
               body: "Token exchange crashed: #{Exception.message(exception)}"
             )}
        catch
          kind, reason ->
            {:error,
             Sycophant.Error.Provider.ServerError.exception(
               body: "Token exchange exited (#{kind}): #{inspect(reason)}"
             )}
        end

      send(parent, {:refresh_done, cache_key, result})
    end)
  end

  defp insert_with_lru(entries, cache_key, entry) do
    cond do
      Map.has_key?(entries, cache_key) ->
        Map.put(entries, cache_key, entry)

      map_size(entries) < @max_entries ->
        Map.put(entries, cache_key, entry)

      true ->
        {oldest_key, _} =
          entries
          |> Enum.reject(fn {k, _} -> k == cache_key end)
          |> Enum.min_by(fn {_, %Entry{fetched_at: t}} -> t end, DateTime)

        entries
        |> Map.delete(oldest_key)
        |> Map.put(cache_key, entry)
    end
  end
end
