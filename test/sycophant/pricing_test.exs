defmodule Sycophant.PricingTest do
  use ExUnit.Case, async: true

  alias Sycophant.Pricing
  alias Sycophant.Pricing.Component
  alias Sycophant.Serializable
  alias Sycophant.Serializable.Decoder

  @llmdb_pricing %{
    currency: "USD",
    components: [
      %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
      %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 15.0},
      %{id: "token.cache_read", kind: "token", unit: "token", per: 1_000_000, rate: 0.3},
      %{id: "token.cache_write", kind: "token", unit: "token", per: 1_000_000, rate: 3.75},
      %{
        id: "tool.web_search",
        kind: "tool",
        unit: "call",
        per: 1000,
        rate: 10.0,
        tool: "web_search"
      }
    ]
  }

  describe "from_llmdb/1" do
    test "converts LLMDB pricing map to struct" do
      pricing = Pricing.from_llmdb(@llmdb_pricing)

      assert pricing.currency == "USD"
      assert length(pricing.components) == 5
      assert [%Component{id: "token.input", rate: 3.0} | _] = pricing.components
    end

    test "preserves tool-specific fields" do
      pricing = Pricing.from_llmdb(@llmdb_pricing)
      web_search = Enum.find(pricing.components, &(&1.id == "tool.web_search"))

      assert web_search.tool == "web_search"
      assert web_search.kind == "tool"
      assert web_search.per == 1000
    end

    test "handles components with optional fields" do
      llmdb = %{
        currency: "USD",
        components: [
          %{
            id: "image.input",
            kind: "image",
            unit: "image",
            per: 1,
            rate: 0.01,
            size_class: "low",
            notes: "Low resolution"
          }
        ]
      }

      pricing = Pricing.from_llmdb(llmdb)
      [comp] = pricing.components

      assert comp.size_class == "low"
      assert comp.notes == "Low resolution"
      assert comp.tool == nil
      assert comp.meter == nil
    end
  end

  describe "from_map/1" do
    test "reconstructs from string-keyed map" do
      map = %{
        "currency" => "USD",
        "components" => [
          %{
            "id" => "token.input",
            "kind" => "token",
            "unit" => "token",
            "per" => 1_000_000,
            "rate" => 3.0
          }
        ]
      }

      pricing = Pricing.from_map(map)

      assert pricing.currency == "USD"
      assert [%Component{id: "token.input"}] = pricing.components
    end

    test "handles missing components key" do
      map = %{"currency" => "EUR"}
      pricing = Pricing.from_map(map)

      assert pricing.currency == "EUR"
      assert pricing.components == []
    end
  end

  describe "find_component/2" do
    test "finds component by ID" do
      pricing = Pricing.from_llmdb(@llmdb_pricing)

      assert %Component{id: "token.input", rate: 3.0} =
               Pricing.find_component(pricing, "token.input")
    end

    test "returns nil for missing component" do
      pricing = Pricing.from_llmdb(@llmdb_pricing)
      assert Pricing.find_component(pricing, "token.reasoning") == nil
    end
  end

  describe "Component.from_llmdb/1" do
    test "converts atom-keyed map to struct" do
      map = %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0}
      comp = Component.from_llmdb(map)

      assert comp.id == "token.input"
      assert comp.kind == "token"
      assert comp.unit == "token"
      assert comp.per == 1_000_000
      assert comp.rate == 3.0
    end

    test "ignores unknown keys" do
      map = %{id: "token.input", kind: "token", unknown_field: "ignored"}
      comp = Component.from_llmdb(map)

      assert comp.id == "token.input"
      assert comp.kind == "token"
    end
  end

  describe "Component.from_map/1" do
    test "reconstructs from string-keyed map" do
      map = %{
        "id" => "token.output",
        "kind" => "token",
        "unit" => "token",
        "per" => 1_000_000,
        "rate" => 15.0,
        "meter" => "output"
      }

      comp = Component.from_map(map)

      assert comp.id == "token.output"
      assert comp.meter == "output"
    end
  end

  describe "serialization round-trip" do
    test "Pricing round-trips through JSON" do
      original = Pricing.from_llmdb(@llmdb_pricing)
      json = Serializable.to_map(original) |> JSON.encode!()
      restored = json |> JSON.decode!() |> Pricing.from_map()

      assert restored.currency == original.currency
      assert length(restored.components) == length(original.components)

      for {orig, rest} <- Enum.zip(original.components, restored.components) do
        assert orig.id == rest.id
        assert orig.rate == rest.rate
        assert orig.per == rest.per
      end
    end

    test "Pricing round-trips through Decoder" do
      original = Pricing.from_llmdb(@llmdb_pricing)
      json = Decoder.encode(original)
      restored = Decoder.decode(json)

      assert restored.currency == original.currency
      assert length(restored.components) == length(original.components)
    end

    test "Component round-trips through Decoder" do
      original = %Component{
        id: "tool.web_search",
        kind: "tool",
        unit: "call",
        per: 1000,
        rate: 10.0,
        tool: "web_search"
      }

      json = Decoder.encode(original)
      restored = Decoder.decode(json)

      assert restored.id == original.id
      assert restored.tool == original.tool
      assert restored.per == original.per
    end

    test "Component compacts nil fields" do
      comp = %Component{
        id: "token.input",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 3.0
      }

      map = Serializable.to_map(comp)

      refute Map.has_key?(map, "tool")
      refute Map.has_key?(map, "meter")
      refute Map.has_key?(map, "size_class")
      refute Map.has_key?(map, "notes")
    end

    test "Pricing serialization includes __type__ discriminator" do
      pricing = Pricing.from_llmdb(@llmdb_pricing)
      map = Serializable.to_map(pricing)

      assert map["__type__"] == "Pricing"
    end

    test "Component serialization includes __type__ discriminator" do
      comp = %Component{
        id: "token.input",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 3.0
      }

      map = Serializable.to_map(comp)

      assert map["__type__"] == "PricingComponent"
    end
  end
end
