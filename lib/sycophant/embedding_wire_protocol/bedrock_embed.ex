defmodule Sycophant.EmbeddingWireProtocol.BedrockEmbed do
  @moduledoc """
  Wire protocol adapter for AWS Bedrock embedding models.

  Uses the `/model/{model}/invoke` endpoint. Translates canonical
  EmbeddingRequest into the Cohere Embed v4 JSON format and normalizes
  the response to always use the keyed-by-type embeddings shape.
  """

  @behaviour Sycophant.EmbeddingWireProtocol

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Error.Provider.ResponseInvalid
  alias Sycophant.Message.Content
  alias Sycophant.Usage

  @impl true
  def request_path(%EmbeddingRequest{} = request) do
    encoded_model = URI.encode(request.model, &(&1 != ?:))
    "/model/#{encoded_model}/invoke"
  end

  @impl true
  def encode_request(%EmbeddingRequest{} = request) do
    payload =
      classify_inputs(request.inputs)
      |> Map.merge(translate_params(request.params))
      |> Map.merge(request.provider_params || %{})

    {:ok, payload}
  end

  @impl true
  def decode_response(%{"embeddings" => embeddings} = body, headers) when is_list(embeddings) do
    {:ok,
     %EmbeddingResponse{
       embeddings: %{float: embeddings},
       model: nil,
       usage: decode_usage(body, headers),
       raw: body
     }}
  end

  def decode_response(%{"embeddings" => embeddings} = body, headers) when is_map(embeddings) do
    typed =
      Map.new(embeddings, fn {k, v} ->
        {String.to_existing_atom(k), v}
      end)

    {:ok,
     %EmbeddingResponse{
       embeddings: typed,
       model: nil,
       usage: decode_usage(body, headers),
       raw: body
     }}
  end

  def decode_response(body, _headers) do
    {:error, ResponseInvalid.exception(raw: body)}
  end

  defp classify_inputs(inputs) do
    cond do
      all_strings?(inputs) -> %{"texts" => inputs}
      all_images?(inputs) -> %{"images" => Enum.map(inputs, &encode_image/1)}
      true -> %{"inputs" => Enum.map(inputs, &encode_mixed_input/1)}
    end
  end

  defp all_strings?(inputs), do: Enum.all?(inputs, &is_binary/1)

  defp all_images?(inputs) do
    Enum.all?(inputs, fn
      %Content.Image{} -> true
      _ -> false
    end)
  end

  defp encode_image(%Content.Image{data: data, media_type: media_type}) do
    "data:#{media_type};base64,#{data}"
  end

  defp encode_mixed_input(input) when is_binary(input) do
    %{"content" => [%{"type" => "text", "text" => input}]}
  end

  defp encode_mixed_input(%Content.Image{} = img) do
    %{"content" => [%{"type" => "image_url", "image_url" => encode_image(img)}]}
  end

  defp encode_mixed_input(parts) when is_list(parts) do
    content = Enum.map(parts, &encode_content_part/1)
    %{"content" => content}
  end

  defp encode_content_part(text) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  defp encode_content_part(%Content.Image{} = img) do
    %{"type" => "image_url", "image_url" => encode_image(img)}
  end

  defp translate_params(nil), do: %{}

  defp translate_params(%EmbeddingParams{} = params) do
    base = %{
      "embedding_types" => Enum.map(params.embedding_types, &Atom.to_string/1),
      "truncate" => params.truncate |> Atom.to_string() |> String.upcase()
    }

    base
    |> maybe_put("output_dimension", params.dimensions)
    |> maybe_put("max_tokens", params.max_tokens)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_usage(body, headers) do
    case get_header(headers, "x-amzn-bedrock-input-token-count") do
      nil -> decode_usage_from_body(body)
      value -> %Usage{input_tokens: String.to_integer(value)}
    end
  end

  defp decode_usage_from_body(%{"meta" => %{"billed_units" => %{"input_tokens" => input}}}) do
    %Usage{input_tokens: input}
  end

  defp decode_usage_from_body(_), do: nil

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
