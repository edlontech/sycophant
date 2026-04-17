defmodule Sycophant.Message.Content.RedactedThinking do
  @moduledoc """
  Redacted/encrypted thinking content part for assistant messages.

  Carries opaque encrypted data that some providers return when parts
  of the model's reasoning are redacted. Required for multi-turn
  conversations where the provider needs the encrypted blob sent back
  to maintain reasoning continuity.

  ## Examples

      iex> %Sycophant.Message.Content.RedactedThinking{data: "encrypted_blob"}
      #Sycophant.Message.Content.RedactedThinking<%{data: "**REDACTED**"}>
  """
  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: String.t()}

  @doc "Deserializes a redacted thinking content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(%{"data" => data}), do: %__MODULE__{data: data}
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.RedactedThinking do
  def to_map(%{data: data}),
    do: %{"__type__" => "RedactedThinking", "type" => "redacted_thinking", "data" => data}
end

defimpl Inspect, for: Sycophant.Message.Content.RedactedThinking do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(redacted, opts) do
    concat([
      "#Sycophant.Message.Content.RedactedThinking<",
      to_doc(%{data: InspectHelpers.redact(redacted.data)}, opts),
      ">"
    ])
  end
end
