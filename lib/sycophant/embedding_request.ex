defmodule Sycophant.EmbeddingRequest do
  @moduledoc """
  Input struct for embedding requests.

  Each element in `inputs` produces one embedding vector. Elements can be
  plain text strings, image content parts, or mixed lists.

  ## Examples

      # Text embeddings
      %Sycophant.EmbeddingRequest{
        inputs: ["Hello world", "Goodbye world"],
        model: "amazon_bedrock:cohere.embed-english-v3"
      }

      # With parameters
      %Sycophant.EmbeddingRequest{
        inputs: ["Hello world"],
        model: "amazon_bedrock:cohere.embed-english-v3",
        params: %Sycophant.EmbeddingParams{dimensions: 256, embedding_types: [:float, :int8]}
      }
  """
  use TypedStruct

  alias Sycophant.EmbeddingParams
  alias Sycophant.Message.Content

  @type input :: String.t() | Content.Image.t() | [String.t() | Content.Image.t()]

  typedstruct do
    field :inputs, [input()], enforce: true
    field :model, String.t(), enforce: true
    field :params, EmbeddingParams.t()
    field :provider_params, map(), default: %{}
  end

  @doc "Reconstructs an EmbeddingRequest struct from a serialized map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      inputs: decode_inputs(data["inputs"] || []),
      model: data["model"],
      params: decode_params(data["params"]),
      provider_params: data["provider_params"] || %{}
    }
  end

  defp decode_params(nil), do: nil
  defp decode_params(data), do: EmbeddingParams.from_map(data)

  defp decode_inputs(inputs), do: Enum.map(inputs, &decode_input/1)

  defp decode_input(input) when is_binary(input), do: input
  defp decode_input(%{"__type__" => "Image"} = data), do: Content.Image.from_map(data)
  defp decode_input(parts) when is_list(parts), do: Enum.map(parts, &decode_input/1)
end

defimpl Sycophant.Serializable, for: Sycophant.EmbeddingRequest do
  import Sycophant.Serializable.Helpers

  def to_map(req) do
    compact(%{
      "__type__" => "EmbeddingRequest",
      "inputs" => Enum.map(req.inputs, &encode_input/1),
      "model" => req.model,
      "params" => maybe_to_map(req.params),
      "provider_params" => if(req.provider_params == %{}, do: nil, else: req.provider_params)
    })
  end

  defp encode_input(input) when is_binary(input), do: input

  defp encode_input(%Sycophant.Message.Content.Image{} = img),
    do: Sycophant.Serializable.to_map(img)

  defp encode_input(parts) when is_list(parts), do: Enum.map(parts, &encode_input/1)

  defp maybe_to_map(nil), do: nil
  defp maybe_to_map(struct), do: Sycophant.Serializable.to_map(struct)
end

defimpl Inspect, for: Sycophant.EmbeddingRequest do
  import Inspect.Algebra

  def inspect(req, opts) do
    fields =
      Enum.reject(
        [
          model: req.model,
          inputs: length(req.inputs),
          params: req.params
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.EmbeddingRequest<", to_doc(Map.new(fields), opts), ">"])
  end
end
