defmodule Sycophant.Message.Content.DocumentTest do
  use ExUnit.Case, async: true

  alias Sycophant.Message.Content.Document
  alias Sycophant.Serializable

  describe "from_map/1 + Serializable.to_map/1 round-trip" do
    test "data source" do
      original = %Document{data: "JVBERi0=", media_type: "application/pdf", name: "r.pdf"}
      assert original == original |> Serializable.to_map() |> Document.from_map()
    end

    test "url source" do
      original = %Document{url: "https://example.com/r.pdf", media_type: "application/pdf"}
      assert original == original |> Serializable.to_map() |> Document.from_map()
    end

    test "file_id source" do
      original = %Document{file_id: "file_123", media_type: "text/csv", name: "data.csv"}
      assert original == original |> Serializable.to_map() |> Document.from_map()
    end

    test "citations flag round-trips" do
      original = %Document{url: "https://x/r.pdf", media_type: "application/pdf", citations: true}
      assert original == original |> Serializable.to_map() |> Document.from_map()
    end

    test "defaults citations to false" do
      assert %Document{citations: false} = Document.from_map(%{"data" => "abc"})
    end

    test "to_map carries __type__ and compacts nil source fields" do
      map = Serializable.to_map(%Document{data: "abc", media_type: "application/pdf"})
      assert map["__type__"] == "Document"
      assert map["type"] == "document"
      refute Map.has_key?(map, "url")
      refute Map.has_key?(map, "file_id")
      assert map["citations"] == false
    end
  end

  describe "Inspect" do
    test "redacts base64 data" do
      doc = %Document{data: "JVBERi0xLjQK...", media_type: "application/pdf"}
      result = inspect(doc)
      assert result =~ "#Sycophant.Message.Content.Document<"
      assert result =~ "**REDACTED**"
      refute result =~ "JVBERi0xLjQK"
    end

    test "shows url and name when present" do
      doc = %Document{url: "https://example.com/r.pdf", name: "r.pdf"}
      result = inspect(doc)
      assert result =~ "https://example.com/r.pdf"
      assert result =~ "r.pdf"
    end

    test "suppresses default citations: false but shows citations: true" do
      refute inspect(%Document{url: "https://x/r.pdf"}) =~ "citations"
      assert inspect(%Document{url: "https://x/r.pdf", citations: true}) =~ "citations: true"
    end
  end
end
