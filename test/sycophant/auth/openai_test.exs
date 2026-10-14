defmodule Sycophant.Auth.OpenAITest do
  use ExUnit.Case, async: true

  alias Sycophant.Auth.OpenAI
  alias Sycophant.Error.Invalid.InvalidParams

  test "nil access token falls through to API-key authentication and default constraints" do
    assert OpenAI.middlewares(%{access_token: nil, api_key: "k"}) ==
             [{Tesla.Middleware.Headers, [{"authorization", "Bearer k"}]}]

    assert OpenAI.middlewares(%{access_token: nil}) == []

    assert OpenAI.request_constraints(%{access_token: nil}, %{}) ==
             %Sycophant.Auth.RequestConstraints{}
  end

  test "rejects ambiguous credentials without exposing either secret" do
    assert {:error, %InvalidParams{} = error} =
             OpenAI.prepare_credentials(%{access_token: "secret-token", api_key: "secret-key"})

    message = Exception.message(error)
    assert message =~ "access_token"
    assert message =~ "api_key"
    refute inspect(error) =~ "secret-token"
    refute inspect(error) =~ "secret-key"

    for credentials <- [%{api_key: "k"}, %{access_token: "t"}, %{}] do
      assert OpenAI.prepare_credentials(credentials) == {:ok, credentials}
    end
  end

  test "restricts subscriptions and includes encrypted reasoning only for reasoning models" do
    for enabled <- [true, false, nil] do
      model_info = %{
        model_struct: %LLMDB.Model{
          id: "model",
          provider: :openai,
          capabilities: %{reasoning: %{enabled: enabled}}
        }
      }

      constraints = OpenAI.request_constraints(%{access_token: "t"}, model_info)

      assert constraints.unsupported_params == [
               :temperature,
               :top_p,
               :max_tokens,
               :max_tool_calls,
               :metadata,
               :cache_retention,
               :safety_identifier,
               :top_logprobs,
               :truncation,
               :previous_response_id
             ]

      assert constraints.require_stream

      expected =
        if enabled == true,
          do: %{store: false, include: ["reasoning.encrypted_content"]},
          else: %{store: false}

      assert constraints.forced_params == expected

      assert OpenAI.request_constraints(%{api_key: "k"}, model_info) ==
               %Sycophant.Auth.RequestConstraints{}
    end

    assert OpenAI.request_constraints(%{access_token: "t"}, %{model_struct: %{}}).forced_params ==
             %{store: false}
  end

  test "uses bearer authentication for either credential mode" do
    assert OpenAI.middlewares(%{access_token: "t"}) ==
             [{Tesla.Middleware.Headers, [{"authorization", "Bearer t"}]}]

    assert OpenAI.middlewares(%{api_key: "k"}) ==
             [{Tesla.Middleware.Headers, [{"authorization", "Bearer k"}]}]

    assert OpenAI.middlewares(%{}) == []
  end
end
