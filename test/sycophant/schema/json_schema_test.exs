defmodule Sycophant.Schema.JsonSchemaTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidSchema
  alias Sycophant.Schema.JsonSchema

  describe "to_json_schema/1" do
    test "converts string schema" do
      assert {:ok, %{"type" => "string"}} = JsonSchema.to_json_schema(Zoi.string())
    end

    test "converts integer schema" do
      assert {:ok, %{"type" => "integer"}} = JsonSchema.to_json_schema(Zoi.integer())
    end

    test "converts float schema" do
      assert {:ok, %{"type" => "number"}} = JsonSchema.to_json_schema(Zoi.float())
    end

    test "converts number schema" do
      assert {:ok, %{"type" => "number"}} = JsonSchema.to_json_schema(Zoi.number())
    end

    test "converts boolean schema" do
      assert {:ok, %{"type" => "boolean"}} = JsonSchema.to_json_schema(Zoi.boolean())
    end

    test "converts string with min/max constraints" do
      schema = Zoi.string() |> Zoi.min(3) |> Zoi.max(10)
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "string"
      assert result["minLength"] == 3
      assert result["maxLength"] == 10
    end

    test "converts float with min/max constraints" do
      schema = Zoi.float() |> Zoi.min(0.0) |> Zoi.max(1.0)
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "number"
      assert result["minimum"] == 0.0
      assert result["maximum"] == 1.0
    end

    test "converts integer with positive constraint" do
      schema = Zoi.positive(Zoi.integer())
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "integer"
      assert result["exclusiveMinimum"] == 0
    end

    test "converts enum with atom values to strings" do
      schema = Zoi.enum([:admin, :user, :guest])
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "string"
      assert result["enum"] == ["admin", "user", "guest"]
    end

    test "converts list schema" do
      schema = Zoi.list(Zoi.string())
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "array"
      assert result["items"] == %{"type" => "string"}
    end

    test "converts map schema with required and optional fields" do
      schema =
        Zoi.map(%{
          name: Zoi.string(),
          age: Zoi.optional(Zoi.integer())
        })

      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "object"
      assert result["properties"]["name"] == %{"type" => "string"}
      assert result["properties"]["age"] == %{"type" => "integer"}
      assert "name" in result["required"]
      refute "age" in result["required"]
    end

    test "converts nested map schema" do
      schema =
        Zoi.map(%{
          address:
            Zoi.map(%{
              street: Zoi.string(),
              city: Zoi.string()
            })
        })

      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      address = result["properties"]["address"]
      assert address["type"] == "object"
      assert address["properties"]["street"] == %{"type" => "string"}
    end

    test "converts union schema to anyOf" do
      schema = Zoi.union([Zoi.string(), Zoi.integer()])
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["anyOf"] == [%{"type" => "string"}, %{"type" => "integer"}]
    end

    test "converts nullable to anyOf with null" do
      schema = Zoi.nullable(Zoi.string())
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert %{"type" => "null"} in result["anyOf"]
      assert %{"type" => "string"} in result["anyOf"]
    end

    test "converts literal to const" do
      schema = Zoi.literal("fixed")
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["const"] == "fixed"
    end

    test "converts email format" do
      schema = Zoi.email()
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "string"
      assert result["format"] == "email"
      assert is_binary(result["pattern"])
    end

    test "converts url format" do
      schema = Zoi.url()
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["format"] == "uri"
    end

    test "converts date format" do
      assert {:ok, result} = JsonSchema.to_json_schema(Zoi.date())
      assert result["format"] == "date"
    end

    test "converts datetime format" do
      assert {:ok, result} = JsonSchema.to_json_schema(Zoi.datetime())
      assert result["format"] == "date-time"
    end

    test "strips $schema key" do
      assert {:ok, result} = JsonSchema.to_json_schema(Zoi.string())
      refute Map.has_key?(result, "$schema")
    end

    test "all keys are strings" do
      schema = Zoi.map(%{name: Zoi.string(), tags: Zoi.list(Zoi.string())})
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert Enum.all?(Map.keys(result), &is_binary/1)
      assert Enum.all?(Map.keys(result["properties"]), &is_binary/1)
    end

    test "returns error for unsupported schema types" do
      assert {:error, %InvalidSchema{errors: [msg]}} =
               JsonSchema.to_json_schema(Zoi.function())

      assert msg =~ "not implemented"
    end

    test "converts list with min/max length" do
      schema = Zoi.list(Zoi.string()) |> Zoi.min(1) |> Zoi.max(5)
      assert {:ok, result} = JsonSchema.to_json_schema(schema)
      assert result["type"] == "array"
      assert result["minItems"] == 1
      assert result["maxItems"] == 5
    end
  end
end
