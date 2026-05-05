defmodule Sycophant.Auth.GithubCopilot.TokenCacheTest do
  use ExUnit.Case, async: false

  use Mimic

  alias Sycophant.Auth.GithubCopilot.Exchange
  alias Sycophant.Auth.GithubCopilot.TokenCache
  alias Sycophant.Error

  setup_all do
    Supervisor.terminate_child(Sycophant.Supervisor, TokenCache)

    on_exit(fn ->
      Supervisor.restart_child(Sycophant.Supervisor, TokenCache)
    end)

    :ok
  end

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    Mimic.copy(Exchange)
    start_supervised!(TokenCache)
    :ok
  end

  describe "fetch/2 - happy path" do
    test "returns cached entry on second call without re-exchanging" do
      Exchange
      |> expect(:exchange, 1, fn "github.com", "ghp_x" -> {:ok, valid_entry_map()} end)

      assert {:ok, entry1} = TokenCache.fetch("github.com", "ghp_x")
      assert {:ok, entry2} = TokenCache.fetch("github.com", "ghp_x")
      assert entry1 == entry2
    end
  end

  describe "fetch/2 - concurrency" do
    test "two concurrent fetches on same key produce one exchange call" do
      Exchange
      |> expect(:exchange, 1, fn _, _ ->
        Process.sleep(50)
        {:ok, valid_entry_map()}
      end)

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> TokenCache.fetch("github.com", "ghp_x") end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "fetches on different keys are independent" do
      Exchange
      |> expect(:exchange, 2, fn _, token ->
        {:ok, valid_entry_map(token)}
      end)

      assert {:ok, e1} = TokenCache.fetch("github.com", "ghp_a")
      assert {:ok, e2} = TokenCache.fetch("github.com", "ghp_b")
      refute e1.copilot_token == e2.copilot_token
    end
  end

  describe "fetch/2 - refresh" do
    test "refreshes near expiry" do
      Exchange
      |> expect(:exchange, 2, fn _, _ ->
        {:ok, %{valid_entry_map() | expires_at: DateTime.add(DateTime.utc_now(), 5, :second)}}
      end)

      assert {:ok, _} = TokenCache.fetch("github.com", "ghp_x")
      assert {:ok, _} = TokenCache.fetch("github.com", "ghp_x")
    end

    test "delivers same error to all waiters when refresh fails" do
      Exchange
      |> expect(:exchange, 1, fn _, _ ->
        Process.sleep(20)
        {:error, Error.Provider.RateLimited.exception([])}
      end)

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> TokenCache.fetch("github.com", "ghp_x") end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &match?({:error, %Error.Provider.RateLimited{}}, &1))
    end
  end

  describe "fetch/2 - LRU eviction" do
    test "evicts oldest entry at 33rd insert" do
      Exchange
      |> expect(:exchange, 33, fn _, token -> {:ok, valid_entry_map(token)} end)

      for i <- 1..33 do
        assert {:ok, _} = TokenCache.fetch("github.com", "tok_#{i}")
        Process.sleep(2)
      end

      Exchange
      |> expect(:exchange, 1, fn _, "tok_1" -> {:ok, valid_entry_map("tok_1")} end)

      assert {:ok, _} = TokenCache.fetch("github.com", "tok_1")
    end

    test "re-inserting an existing key at cap does not evict any other entry" do
      Exchange
      |> expect(:exchange, 32, fn _, token ->
        if token == "tok_5" do
          {:ok,
           %{valid_entry_map(token) | expires_at: DateTime.add(DateTime.utc_now(), 5, :second)}}
        else
          {:ok, valid_entry_map(token)}
        end
      end)

      for i <- 1..32 do
        assert {:ok, _} = TokenCache.fetch("github.com", "tok_#{i}")
        Process.sleep(2)
      end

      Exchange
      |> expect(:exchange, 1, fn _, "tok_5" -> {:ok, valid_entry_map("tok_5")} end)

      assert {:ok, _} = TokenCache.fetch("github.com", "tok_5")

      for i <- 1..32, i != 5 do
        assert {:ok, _} = TokenCache.fetch("github.com", "tok_#{i}")
      end
    end
  end

  describe "fetch/2 - refresh task crash" do
    test "returns ServerError and clears refreshing slot when exchange raises" do
      Exchange
      |> expect(:exchange, 1, fn _, _ -> raise ArgumentError, message: "bad timestamp" end)

      assert {:error, %Error.Provider.ServerError{} = err} =
               TokenCache.fetch("github.com", "ghp_x")

      assert err.body =~ "bad timestamp"

      Exchange
      |> expect(:exchange, 1, fn _, _ -> {:ok, valid_entry_map()} end)

      assert {:ok, _entry} = TokenCache.fetch("github.com", "ghp_x")
    end
  end

  defp valid_entry_map(token \\ "tid=abc") do
    %{
      copilot_token: token,
      expires_at: DateTime.add(DateTime.utc_now(), 1500, :second),
      endpoints: %{
        api: "https://api.individual.githubcopilot.com",
        proxy: nil,
        telemetry: nil
      },
      fetched_at: DateTime.utc_now()
    }
  end
end
