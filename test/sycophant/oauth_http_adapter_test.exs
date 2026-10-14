defmodule Sycophant.OAuth.HTTPAdapterTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Assent.HTTPAdapter.HTTPResponse
  alias Sycophant.OAuth.HTTPAdapter

  test "returns connection failures unchanged" do
    expect(Tesla, :post, fn _client, _url, _body, [] -> {:error, :econnrefused} end)

    assert HTTPAdapter.request(:post, "https://auth.openai.com/token", "a=b", [], []) ==
             {:error, :econnrefused}
  end

  test "uses the configured adapter and headers without JSON or logging middleware" do
    adapter = fn env ->
      assert env.method == :get
      assert env.headers == [{"authorization", "Bearer secret-access"}]
      {:ok, %{env | status: 200, body: "{\"raw\":true}"}}
    end

    stub(Sycophant.Config, :tesla, fn ->
      {:ok, %{adapter: adapter, middlewares: [Tesla.Middleware.JSON, Tesla.Middleware.Logger]}}
    end)

    assert {:ok, %HTTPResponse{body: "{\"raw\":true}"}} =
             HTTPAdapter.request(
               :get,
               "https://auth.openai.com/userinfo",
               nil,
               [{"authorization", "Bearer secret-access"}],
               nil
             )
  end

  test "posts the raw form body and preserves HTTP responses, including errors" do
    url = "https://auth.openai.com/api/accounts/oauth/token"
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    response_headers = [{"content-type", "application/json"}, {"x-request-id", "request-id"}]

    for status <- [200, 400, 500] do
      expect(Tesla, :post, fn _client, ^url, "a=b", [] ->
        {:ok, %Tesla.Env{status: status, headers: response_headers, body: "{\"ok\":true}"}}
      end)

      assert {:ok,
              %HTTPResponse{
                status: ^status,
                headers: ^response_headers,
                body: "{\"ok\":true}",
                http_adapter: HTTPAdapter,
                request_url: ^url
              }} = HTTPAdapter.request(:post, url, "a=b", headers, [])
    end
  end
end
