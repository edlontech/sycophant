defmodule Sycophant.Reasoning do
  @moduledoc """
  Reasoning output from an LLM response.

  When a model supports extended thinking (e.g. with the `:reasoning` parameter),
  the reasoning summary is available in `response.reasoning.summary`. The
  `:encrypted_content` field carries opaque data for stateless multi-turn
  reasoning that is automatically included in continuation calls.

  ## Examples

      iex> %Sycophant.Reasoning{summary: "The user asked about capitals..."}
      %Sycophant.Reasoning{summary: "The user asked about capitals...", encrypted_content: nil}
  """
  use TypedStruct

  typedstruct do
    field :summary, String.t()
    field :encrypted_content, String.t()
  end

  @doc "Deserializes reasoning output from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{summary: data["summary"], encrypted_content: data["encrypted_content"]}
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Reasoning do
  import Sycophant.Serializable.Helpers

  def to_map(r) do
    compact(%{
      "__type__" => "Reasoning",
      "summary" => r.summary,
      "encrypted_content" => r.encrypted_content
    })
  end
end
