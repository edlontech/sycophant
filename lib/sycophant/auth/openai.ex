defmodule Sycophant.Auth.OpenAI do
  @moduledoc """
  OpenAI authentication using an API key or a ChatGPT access token.

  Access tokens apply subscription request restrictions; API keys retain
  unrestricted Bearer authentication.

  On the access-token route OpenAI ignores the body `prompt_cache_key` and
  routes prompt caching by the `session_id` header instead. Pass a stable
  `:session_id` (for example, a conversation ID) in the credentials to get
  prompt cache hits across turns.
  """

  @behaviour Sycophant.Auth

  alias Sycophant.Auth.Bearer
  alias Sycophant.Auth.RequestConstraints
  alias Sycophant.Error.Invalid.InvalidParams

  @impl true
  def prepare_credentials(%{access_token: _, api_key: _}) do
    {:error, InvalidParams.exception(errors: ["Provide only one of :access_token or :api_key"])}
  end

  def prepare_credentials(credentials), do: {:ok, credentials}

  @impl true
  def middlewares(%{access_token: token} = credentials) when is_binary(token) do
    session_header =
      case credentials[:session_id] do
        id when is_binary(id) -> [{"session_id", id}]
        _ -> []
      end

    [{Tesla.Middleware.Headers, [{"authorization", "Bearer #{token}"} | session_header]}]
  end

  def middlewares(credentials), do: Bearer.middlewares(credentials)

  @impl true
  def request_constraints(%{access_token: token}, model_info) when is_binary(token),
    do: subscription_constraints(model_info)

  def request_constraints(_credentials, _model_info), do: %RequestConstraints{}

  defp subscription_constraints(model_info) do
    reasoning =
      get_in(model_info, [:model_struct, Access.key(:capabilities, %{}), :reasoning, :enabled])

    forced_params =
      if reasoning == true,
        do: %{store: false, include: ["reasoning.encrypted_content"]},
        else: %{store: false}

    %RequestConstraints{
      unsupported_params: [
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
      ],
      forced_params: forced_params,
      require_stream: true
    }
  end
end
