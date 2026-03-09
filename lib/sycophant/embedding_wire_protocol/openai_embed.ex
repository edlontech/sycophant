defmodule Sycophant.EmbeddingWireProtocol.OpenAIEmbed do
  @moduledoc """
  Wire protocol adapter for OpenAI-compatible embedding APIs.

  Translates canonical EmbeddingRequest into the standard OpenAI
  embedding JSON format and normalizes responses back to
  EmbeddingResponse structs. Used by Azure and other providers
  implementing the OpenAI embedding API.
  """

  @behaviour Sycophant.EmbeddingWireProtocol

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Usage

  @impl true
  def request_path(_request), do: "/embeddings"

  @impl true
  def encode_request(%EmbeddingRequest{} = request) do
    payload =
      %{"model" => request.model, "input" => request.inputs}
      |> maybe_put("dimensions", request.params && request.params.dimensions)
      |> maybe_put("encoding_format", encoding_format(request.params))
      |> Map.merge(request.provider_params || %{})

    {:ok, payload}
  end

  @impl true
  def decode_response(%{"data" => data} = body, _headers) when is_list(data) do
    embeddings =
      data
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(& &1["embedding"])

    {:ok,
     %EmbeddingResponse{
       embeddings: %{float: embeddings},
       model: body["model"],
       usage: decode_usage(body),
       raw: body
     }}
  end

  def decode_response(body, _headers) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  defp encoding_format(nil), do: nil

  defp encoding_format(%EmbeddingParams{embedding_types: types}) do
    cond do
      :float in types -> "float"
      :base64 in types -> "base64"
      true -> nil
    end
  end

  defp decode_usage(%{"usage" => %{"prompt_tokens" => input}}) do
    %Usage{input_tokens: input}
  end

  defp decode_usage(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
