defmodule Sycophant.Error do
  @moduledoc """
  Root error module for Sycophant.

  Errors are organized into three classes:
  - `:invalid` -- caller mistakes, fixable before sending
  - `:provider` -- remote failures from the LLM API
  - `:unknown` -- anything uncategorized
  """
  use Splode,
    error_classes: [
      invalid: Sycophant.Error.Invalid,
      provider: Sycophant.Error.Provider,
      unknown: Sycophant.Error.Unknown
    ],
    unknown_error: Sycophant.Error.Unknown.Unknown
end
