defmodule Sycophant.Error do
  @moduledoc """
  Root error module for Sycophant, built on Splode.

  All errors returned by Sycophant implement `Splode.Error` and are organized
  into three classes:

    * `:invalid` - Caller mistakes that can be fixed before sending
      (e.g., `MissingModel`, `MissingCredentials`, `InvalidParams`)
    * `:provider` - Remote failures from the LLM API
      (e.g., `RateLimited`, `ServerError`, `BadRequest`, `AuthenticationFailed`)
    * `:unknown` - Uncategorized errors

  Pattern match on the error class or specific error module:

      case Sycophant.generate_text("openai:gpt-4o-mini", messages) do
        {:ok, response} -> response.text
        {:error, %Sycophant.Error.Provider.RateLimited{}} -> "Rate limited, retry later"
        {:error, %Sycophant.Error.Invalid.MissingCredentials{}} -> "Missing API key"
        {:error, error} -> Splode.Error.message(error)
      end
  """
  use Splode,
    error_classes: [
      invalid: Sycophant.Error.Invalid,
      provider: Sycophant.Error.Provider,
      unknown: Sycophant.Error.Unknown
    ],
    unknown_error: Sycophant.Error.Unknown.Unknown
end
