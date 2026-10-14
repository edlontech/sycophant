defmodule Sycophant.SubscriptionErrorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Provider.BadRequest
  alias Sycophant.Error.Provider.RateLimited
  alias Sycophant.Error.Provider.ServerError
  alias Sycophant.Error.Provider.SubscriptionError
  alias Sycophant.Transport
  alias Sycophant.WireProtocol.OpenAIResponses

  test "recognizes subscription failures and preserves provider details" do
    body = %{
      "error" => %{
        "code" => "subscription_sharing_usage_limit_exceeded",
        "message" => "Usage limit exceeded",
        "param" => nil
      }
    }

    error = SubscriptionError.from_body(body, [{"X-Request-ID", "req_1"}])

    assert %{
             __struct__: SubscriptionError,
             code: "subscription_sharing_usage_limit_exceeded",
             status: nil,
             param: nil,
             request_id: "req_1",
             detail: "Usage limit exceeded"
           } = error

    assert Exception.message(error) ==
             "ChatGPT plan request rejected (subscription_sharing_usage_limit_exceeded): Usage limit exceeded"
  end

  test "parses JSON bodies and ignores unrelated or malformed errors" do
    body =
      ~s({"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit","param":null}})

    assert %{
             __struct__: SubscriptionError,
             code: "subscription_sharing_usage_limit_exceeded",
             detail: "Limit",
             param: nil
           } = SubscriptionError.from_body(body)

    assert %{__struct__: SubscriptionError, code: "chatpass_v2_not_eligible", param: "model"} =
             SubscriptionError.from_body(%{
               "error" => %{"code" => "chatpass_v2_not_eligible", "param" => "model"}
             })

    for body <- [
          %{"error" => %{"code" => "rate_limit_exceeded"}},
          "not JSON",
          %{},
          "null",
          %{"error" => %{"code" => nil}}
        ] do
      assert SubscriptionError.from_body(body) == nil
    end
  end

  test "HTTP subscription codes take precedence over status-based errors" do
    for {status, code} <- [
          {429, "subscription_sharing_usage_limit_exceeded"},
          {403, "subscription_sharing_user_not_eligible"},
          {500, "chatpass_v2_unavailable"}
        ],
        encode <- [&Function.identity/1, &JSON.encode!/1] do
      env = %Tesla.Env{
        status: status,
        body: encode.(%{"error" => %{"code" => code, "message" => "Rejected"}}),
        headers: [{"x-request-id", "req_1"}]
      }

      assert {:error, %SubscriptionError{status: ^status, code: ^code, request_id: "req_1"}} =
               Transport.map_error(env)
    end

    assert {:error, %RateLimited{}} = Transport.map_error(%Tesla.Env{status: 429, body: %{}})

    assert {:error, %BadRequest{status: 403}} =
             Transport.map_error(%Tesla.Env{status: 403, body: %{}})
  end

  test "failed response events preserve subscription codes instead of generic errors" do
    for code <- ["subscription_sharing_usage_unavailable", "chatpass_v2_unavailable"] do
      event = %{
        event: "response.failed",
        data: %{
          "response" => %{
            "error" => %{"code" => code, "message" => "Unavailable", "param" => "model"}
          }
        }
      }

      assert {:terminate, :failed,
              %SubscriptionError{
                code: ^code,
                status: nil,
                request_id: nil,
                detail: "Unavailable",
                param: "model"
              }} =
               OpenAIResponses.decode_stream_chunk(nil, event)
    end

    event = %{
      event: "response.failed",
      data: %{
        "response" => %{"error" => %{"code" => "server_error", "message" => "Internal error"}}
      }
    }

    assert {:terminate, :failed, %ServerError{body: "Internal error"}} =
             OpenAIResponses.decode_stream_chunk(nil, event)
  end
end
