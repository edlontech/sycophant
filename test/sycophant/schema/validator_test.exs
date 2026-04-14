defmodule Sycophant.Schema.ValidatorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidResponse
  alias Sycophant.Schema.NormalizedSchema
  alias Sycophant.Schema.Validator

  defp build_normalized(json_schema, source) do
    resolved = ExJsonSchema.Schema.resolve(json_schema)

    %NormalizedSchema{
      json_schema: json_schema,
      resolved: resolved,
      source: source
    }
  end

  describe "validate/2 with :zoi source" do
    test "returns atom keys on successful validation" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "age" => %{"type" => "integer"}
            },
            "additionalProperties" => false
          },
          :zoi
        )

      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, result} = Validator.validate(schema, data)
      assert result[:name] == "Alice"
      assert result[:age] == 30
    end

    test "coerces keys recursively in nested objects" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "address" => %{
                "type" => "object",
                "properties" => %{
                  "street" => %{"type" => "string"},
                  "city" => %{"type" => "string"}
                }
              }
            }
          },
          :zoi
        )

      data = %{"address" => %{"street" => "123 Main St", "city" => "Springfield"}}

      assert {:ok, result} = Validator.validate(schema, data)
      assert result[:address][:street] == "123 Main St"
      assert result[:address][:city] == "Springfield"
    end

    test "coerces keys in arrays of objects" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "items" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "id" => %{"type" => "integer"},
                    "label" => %{"type" => "string"}
                  }
                }
              }
            }
          },
          :zoi
        )

      data = %{
        "items" => [
          %{"id" => 1, "label" => "first"},
          %{"id" => 2, "label" => "second"}
        ]
      }

      assert {:ok, result} = Validator.validate(schema, data)
      assert [first, second] = result[:items]
      assert first[:id] == 1
      assert first[:label] == "first"
      assert second[:id] == 2
      assert second[:label] == "second"
    end

    test "falls back to string key when atom does not exist" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "some_extremely_unlikely_key_that_does_not_exist_as_atom_xyz_12345" => %{
                "type" => "string"
              }
            }
          },
          :zoi
        )

      data = %{
        "some_extremely_unlikely_key_that_does_not_exist_as_atom_xyz_12345" => "value"
      }

      assert {:ok, result} = Validator.validate(schema, data)

      assert result["some_extremely_unlikely_key_that_does_not_exist_as_atom_xyz_12345"] ==
               "value"
    end
  end

  describe "validate/2 with :json_schema source" do
    test "returns string keys on successful validation" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "count" => %{"type" => "integer"}
            }
          },
          :json_schema
        )

      data = %{"name" => "Bob", "count" => 5}

      assert {:ok, result} = Validator.validate(schema, data)
      assert result["name"] == "Bob"
      assert result["count"] == 5
    end
  end

  describe "validate/2 validation failure" do
    test "returns {:error, InvalidResponse} on validation failure with path info" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "age" => %{"type" => "integer"}
            },
            "required" => ["name", "age"]
          },
          :zoi
        )

      data = %{"name" => "Alice", "age" => "not_an_integer"}

      assert {:error, %InvalidResponse{errors: errors}} = Validator.validate(schema, data)
      assert is_list(errors)
      assert [_ | _] = errors
    end

    test "returns error when required field is missing" do
      schema =
        build_normalized(
          %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            },
            "required" => ["name"]
          },
          :json_schema
        )

      data = %{}

      assert {:error, %InvalidResponse{errors: errors}} = Validator.validate(schema, data)
      assert [_ | _] = errors
    end
  end
end
