defmodule Sycophant.Auth.GithubCopilot.ExchangeTest do
  use ExUnit.Case, async: false

  use Mimic

  alias Sycophant.Auth.GithubCopilot.Exchange
  alias Sycophant.Error

  setup do
    Mimic.copy(Tesla)
    :ok
  end

  setup :verify_on_exit!

  describe "exchange/2 - URL construction" do
    test "uses api.github.com for github.com host" do
      Tesla
      |> expect(:get, fn _client, url ->
        assert url == "https://api.github.com/copilot_internal/v2/token"
        ok_response()
      end)

      assert {:ok, %{copilot_token: "tid=abc"}} = Exchange.exchange("github.com", "ghp_x")
    end

    test "sends user-agent and editor identity headers (required by api.github.com edge)" do
      Tesla
      |> expect(:get, fn %Tesla.Client{pre: pre}, _url ->
        headers =
          Enum.find_value(pre, [], fn
            {Tesla.Middleware.Headers, :call, [hs]} -> hs
            _ -> nil
          end)

        names = Enum.map(headers, fn {name, _} -> name end)
        assert "user-agent" in names
        assert "editor-version" in names
        assert "editor-plugin-version" in names
        assert "authorization" in names
        assert "accept" in names

        ok_response()
      end)

      assert {:ok, _} = Exchange.exchange("github.com", "ghp_x")
    end

    test "uses /api/v3 prefix for GHE host" do
      Tesla
      |> expect(:get, fn _client, url ->
        assert url == "https://ghe.example.com/api/v3/copilot_internal/v2/token"
        ok_response()
      end)

      assert {:ok, _} = Exchange.exchange("ghe.example.com", "ghp_x")
    end
  end

  describe "exchange/2 - error mapping" do
    for {status, error_module} <- [
          {401, Error.Invalid.MissingCredentials},
          {403, Error.Invalid.MissingCredentials},
          {404, Error.Invalid.MissingCredentials},
          {429, Error.Provider.RateLimited},
          {500, Error.Provider.ServerError},
          {502, Error.Provider.ServerError}
        ] do
      test "maps HTTP #{status} to #{inspect(error_module)}" do
        Tesla
        |> expect(:get, fn _, _ -> {:ok, %Tesla.Env{status: unquote(status), body: %{}}} end)

        assert {:error, err} = Exchange.exchange("github.com", "ghp_x")
        assert err.__struct__ == unquote(error_module)
      end
    end

    test "maps network error to ServerError" do
      Tesla
      |> expect(:get, fn _, _ -> {:error, :timeout} end)

      assert {:error, %Error.Provider.ServerError{}} = Exchange.exchange("github.com", "ghp_x")
    end
  end

  defp ok_response do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: %{
         "token" => "tid=abc",
         "expires_at" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), 1500, :second)),
         "refresh_in" => 1500,
         "endpoints" => %{
           "api" => "https://api.individual.githubcopilot.com",
           "proxy" => "https://proxy.example",
           "telemetry" => "https://telemetry.example"
         }
       }
     }}
  end
end
