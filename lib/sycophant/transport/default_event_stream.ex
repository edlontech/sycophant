defmodule Sycophant.Transport.DefaultEventStream do
  @moduledoc """
  Marks a successful streaming response without a `content-type` as
  `text/event-stream`, so `Tesla.Middleware.SSE` decodes it.

  OpenAI's ChatGPT subscription route answers `/v1/responses` streams with no
  `content-type` header. Responses that carry any content type, and error
  responses, are left unchanged.
  """
  @behaviour Tesla.Middleware

  @impl true
  def call(env, next, _opts) do
    with {:ok, env} <- Tesla.run(env, next) do
      if env.status in 200..299 and is_nil(Tesla.get_header(env, "content-type")) do
        {:ok, Tesla.put_header(env, "content-type", "text/event-stream")}
      else
        {:ok, env}
      end
    end
  end
end
