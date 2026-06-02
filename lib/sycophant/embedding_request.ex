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
  use ZoiDefstruct

  @type input ::
          String.t()
          | Sycophant.Message.Content.Image.t()
          | [String.t() | Sycophant.Message.Content.Image.t()]

  defstruct __type__: Zoi.literal("EmbeddingRequest") |> Zoi.default("EmbeddingRequest"),
            inputs: Zoi.default(Zoi.any(), []),
            model: Zoi.string(),
            params: Zoi.optional(Sycophant.EmbeddingParams.t()),
            provider_params: Zoi.default(Zoi.any(), %{})

  @doc false
  @spec decode(map(), keyword()) :: t()
  def decode(data, _opts) do
    req = Zoi.parse!(__MODULE__.t(), Map.delete(data, "inputs"))
    %{req | inputs: decode_inputs(data["inputs"] || [])}
  end

  defp decode_inputs(inputs), do: Enum.map(inputs, &decode_input/1)
  defp decode_input(input) when is_binary(input), do: input

  defp decode_input(%{"__type__" => "Image"} = data),
    do: Zoi.parse!(Sycophant.Message.Content.Image.t(), data)

  defp decode_input(parts) when is_list(parts), do: Enum.map(parts, &decode_input/1)
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
