defmodule Sycophant.CitationTest do
  use ExUnit.Case, async: true

  alias Sycophant.Citation
  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder

  describe "Decoder.from_map/1 + Serializable.to_map/1 round-trip" do
    test "page_location citation" do
      original = %Citation{
        type: :page_location,
        unit: :page,
        cited_text: "Paris is the capital",
        document_index: 0,
        document_title: "France",
        start_index: 1,
        end_index: 2
      }

      assert original == original |> Serializable.to_map() |> Decoder.from_map()
    end

    test "char_location citation" do
      original = %Citation{
        type: :char_location,
        unit: :char,
        cited_text: "hello",
        document_index: 1,
        start_index: 10,
        end_index: 15
      }

      assert original == original |> Serializable.to_map() |> Decoder.from_map()
    end

    test "content_block_location citation" do
      original = %Citation{
        type: :content_block_location,
        unit: :block,
        cited_text: "blocky",
        document_index: 2,
        start_index: 3,
        end_index: 4
      }

      assert original == original |> Serializable.to_map() |> Decoder.from_map()
    end

    test "web_search_result_location citation" do
      original = %Citation{
        type: :web_search_result_location,
        cited_text: "snippet",
        url: "https://example.com",
        title: "Example"
      }

      assert original == original |> Serializable.to_map() |> Decoder.from_map()
    end

    test "search_result_location citation" do
      original = %Citation{
        type: :search_result_location,
        unit: :block,
        cited_text: "from KB",
        source: "kb://doc/1",
        title: "KB Doc",
        start_index: 0,
        end_index: 1
      }

      assert original == original |> Serializable.to_map() |> Decoder.from_map()
    end

    test "to_map carries __type__ and compacts nil fields" do
      map = Serializable.to_map(%Citation{type: :page_location, unit: :page})
      assert map["__type__"] == "Citation"
      assert map["type"] == "page_location"
      refute Map.has_key?(map, "cited_text")
      refute Map.has_key?(map, "url")
    end

    test "Decoder.from_map rejects unknown type/unit strings" do
      assert_raise Sycophant.Error.Invalid.InvalidSerialization, fn ->
        Decoder.from_map(%{"__type__" => "Citation", "type" => "bogus", "unit" => "bogus"})
      end
    end
  end

  describe "Inspect" do
    test "shows type and truncates cited_text" do
      citation = %Citation{type: :page_location, cited_text: String.duplicate("x", 80)}
      result = inspect(citation)
      assert result =~ "#Sycophant.Citation<"
      assert result =~ "page_location"
      assert result =~ "..."
    end
  end
end
