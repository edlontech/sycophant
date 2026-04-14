defmodule Sycophant.Schema.NormalizerTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidSchema
  alias Sycophant.Schema.NormalizedSchema
  alias Sycophant.Schema.Normalizer

  describe "normalize/1 with Zoi schemas" do
    test "normalizes a Zoi map schema into a NormalizedSchema with source :zoi" do
      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()})

      assert {:ok, %NormalizedSchema{} = normalized} = Normalizer.normalize(schema)
      assert normalized.source == :zoi
      assert %ExJsonSchema.Schema.Root{} = normalized.resolved
      assert normalized.json_schema["type"] == "object"
      assert normalized.json_schema["properties"]["name"] == %{"type" => "string"}
      assert normalized.json_schema["properties"]["age"] == %{"type" => "integer"}
    end

    test "injects additionalProperties: false on top-level object" do
      schema = Zoi.map(%{name: Zoi.string()})

      assert {:ok, normalized} = Normalizer.normalize(schema)
      assert normalized.json_schema["additionalProperties"] == false
    end

    test "injects additionalProperties: false recursively on nested objects" do
      schema =
        Zoi.map(%{
          address:
            Zoi.map(%{
              street: Zoi.string(),
              city: Zoi.string()
            })
        })

      assert {:ok, normalized} = Normalizer.normalize(schema)
      assert normalized.json_schema["additionalProperties"] == false

      address_schema = normalized.json_schema["properties"]["address"]
      assert address_schema["additionalProperties"] == false
    end

    test "preserves existing additionalProperties on JSON Schema input" do
      schema = Zoi.map(%{name: Zoi.string()})
      {:ok, json_schema} = Sycophant.Schema.JsonSchema.to_json_schema(schema)
      json_schema_with_ap = Map.put(json_schema, "additionalProperties", true)

      # When going through normalize with a raw map tagged as :json_schema,
      # additionalProperties should not be injected
      assert {:ok, normalized} = Normalizer.normalize(json_schema_with_ap)
      assert normalized.json_schema["additionalProperties"] == true
    end
  end

  describe "normalize/1 with JSON Schema maps" do
    test "normalizes a plain JSON Schema map with source :json_schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        }
      }

      assert {:ok, %NormalizedSchema{} = normalized} = Normalizer.normalize(schema)
      assert normalized.source == :json_schema
      assert %ExJsonSchema.Schema.Root{} = normalized.resolved
      assert normalized.json_schema == schema
    end

    test "does not inject additionalProperties on JSON Schema input" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        }
      }

      assert {:ok, normalized} = Normalizer.normalize(schema)
      refute Map.has_key?(normalized.json_schema, "additionalProperties")
    end

    test "stringifies atom keys in user-provided JSON Schema" do
      schema = %{
        type: "object",
        properties: %{
          name: %{type: "string"}
        }
      }

      assert {:ok, normalized} = Normalizer.normalize(schema)
      assert normalized.json_schema["type"] == "object"
      assert normalized.json_schema["properties"]["name"]["type"] == "string"
      assert Enum.all?(Map.keys(normalized.json_schema), &is_binary/1)
    end
  end

  describe "normalize/1 draft downgrade" do
    test "downgrades prefixItems to items" do
      schema = %{
        "type" => "array",
        "prefixItems" => [
          %{"type" => "string"},
          %{"type" => "integer"}
        ]
      }

      assert {:ok, normalized} = Normalizer.normalize(schema)

      assert normalized.json_schema["items"] == [
               %{"type" => "string"},
               %{"type" => "integer"}
             ]

      refute Map.has_key?(normalized.json_schema, "prefixItems")
    end

    test "downgrades prefixItems recursively in nested schemas" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "tuple_field" => %{
            "type" => "array",
            "prefixItems" => [%{"type" => "string"}]
          }
        }
      }

      assert {:ok, normalized} = Normalizer.normalize(schema)
      tuple_schema = normalized.json_schema["properties"]["tuple_field"]
      assert tuple_schema["items"] == [%{"type" => "string"}]
      refute Map.has_key?(tuple_schema, "prefixItems")
    end
  end

  describe "normalize/1 error handling" do
    test "returns {:error, InvalidSchema} on invalid input" do
      schema = %{"type" => "not_a_real_type", "properties" => 42}

      result = Normalizer.normalize(schema)

      assert {:error, %InvalidSchema{}} = result
    end
  end
end
