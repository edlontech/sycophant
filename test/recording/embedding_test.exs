defmodule Sycophant.Recording.EmbeddingTest do
  @models Sycophant.RecordingCase.test_embedding_models()
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.EmbeddingParams
  alias Sycophant.EmbeddingRequest

  @tag recording_prefix: true
  test "embeds text inputs", %{model: model} do
    request = %EmbeddingRequest{
      inputs: ["The quick brown fox jumps over the lazy dog"],
      model: model,
      params: %EmbeddingParams{embedding_types: [:float]},
      provider_params: %{"input_type" => "search_document"}
    }

    assert {:ok, response} = Sycophant.embed(request, recording_opts([]))

    assert is_map(response.embeddings)
    assert [vector] = response.embeddings.float
    assert is_list(vector)
    assert vector != []
    assert Enum.all?(vector, &is_float/1)
  end

  @tag recording_prefix: true
  test "embeds multiple texts", %{model: model} do
    request = %EmbeddingRequest{
      inputs: ["first document", "second document", "third document"],
      model: model,
      params: %EmbeddingParams{embedding_types: [:float]},
      provider_params: %{"input_type" => "search_document"}
    }

    assert {:ok, response} = Sycophant.embed(request, recording_opts([]))

    assert length(response.embeddings.float) == 3
  end

  @tag recording_prefix: true
  test "embeds with custom dimensions", %{model: model} do
    request = %EmbeddingRequest{
      inputs: ["test dimension reduction"],
      model: model,
      params: %EmbeddingParams{
        embedding_types: [:float],
        dimensions: 256
      },
      provider_params: %{"input_type" => "search_query"}
    }

    assert {:ok, response} = Sycophant.embed(request, recording_opts([]))

    assert [vector] = response.embeddings.float
    assert length(vector) == 256
  end

  @tag recording_prefix: true
  test "embeds with multiple embedding types", %{model: model} do
    request = %EmbeddingRequest{
      inputs: ["multi-type embedding test"],
      model: model,
      params: %EmbeddingParams{embedding_types: [:float, :int8]},
      provider_params: %{"input_type" => "search_document"}
    }

    assert {:ok, response} = Sycophant.embed(request, recording_opts([]))

    assert is_list(response.embeddings.float)
    assert is_list(response.embeddings.int8)
  end
end
