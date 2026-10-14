defmodule Sycophant.Auth.RequestConstraints do
  @moduledoc """
  Credential-mode restrictions applied by the request pipeline.

  Unsupported parameters are dropped before forced parameters are merged.
  Requiring streaming uses an internal callback when the caller supplies none.
  """

  defstruct unsupported_params: [], forced_params: %{}, require_stream: false

  @type t :: %__MODULE__{
          unsupported_params: [atom()],
          forced_params: map(),
          require_stream: boolean()
        }
end
