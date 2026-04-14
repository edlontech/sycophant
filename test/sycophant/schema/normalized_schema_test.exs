defmodule Sycophant.Schema.NormalizedSchemaTest do
  use ExUnit.Case, async: true

  alias Sycophant.Schema.NormalizedSchema

  test "creates struct with all fields" do
    json_schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
    resolved = ExJsonSchema.Schema.resolve(json_schema)

    normalized = %NormalizedSchema{
      json_schema: json_schema,
      resolved: resolved,
      source: :json_schema
    }

    assert normalized.json_schema == json_schema
    assert normalized.source == :json_schema
    assert %ExJsonSchema.Schema.Root{} = normalized.resolved
  end

  test "enforces json_schema field" do
    assert_raise ArgumentError, fn ->
      struct!(NormalizedSchema, %{
        resolved: ExJsonSchema.Schema.resolve(%{"type" => "object"}),
        source: :json_schema
      })
    end
  end

  test "enforces resolved field" do
    assert_raise ArgumentError, fn ->
      struct!(NormalizedSchema, %{
        json_schema: %{"type" => "object"},
        source: :json_schema
      })
    end
  end

  test "enforces source field" do
    json_schema = %{"type" => "object"}

    assert_raise ArgumentError, fn ->
      struct!(NormalizedSchema, %{
        json_schema: json_schema,
        resolved: ExJsonSchema.Schema.resolve(json_schema)
      })
    end
  end

  test "accepts :zoi as source" do
    json_schema = %{"type" => "object", "properties" => %{"age" => %{"type" => "integer"}}}
    resolved = ExJsonSchema.Schema.resolve(json_schema)

    normalized = %NormalizedSchema{
      json_schema: json_schema,
      resolved: resolved,
      source: :zoi
    }

    assert normalized.source == :zoi
  end
end
