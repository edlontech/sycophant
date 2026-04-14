defmodule Sycophant.ResponseValidatorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Response
  alias Sycophant.ResponseValidator
  alias Sycophant.Schema.Normalizer

  defp build_response(text) do
    %Response{
      text: text,
      context: %Context{messages: []}
    }
  end

  defp normalize!(schema) do
    {:ok, normalized} = Normalizer.normalize(schema)
    normalized
  end

  describe "validate/3 with validation enabled and Zoi source" do
    test "parses JSON and validates, coercing keys to atoms" do
      schema = normalize!(Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true))
      response = build_response(~s({"name": "Alice", "age": 30}))

      assert {:ok, %Response{object: %{name: "Alice", age: 30}}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when schema validation fails" do
      schema = normalize!(Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true))
      response = build_response(~s({"name": 123}))

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end
  end

  describe "validate/3 with validation enabled and JSON Schema source" do
    test "parses JSON and validates, keeping string keys" do
      schema =
        normalize!(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})

      response = build_response(~s({"name": "Alice"}))

      assert {:ok, %Response{object: %{"name" => "Alice"}}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when schema validation fails" do
      schema =
        normalize!(%{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        })

      response = build_response(~s({"other": "value"}))

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end
  end

  describe "validate/3 with validation disabled" do
    test "skips schema validation and returns string keys for Zoi source" do
      schema = normalize!(Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true))
      response = build_response(~s({"name": "Alice", "age": 30}))

      assert {:ok, %Response{object: %{"name" => "Alice", "age" => 30}}} =
               ResponseValidator.validate(response, schema, false)
    end

    test "skips schema validation and returns string keys for JSON Schema source" do
      schema =
        normalize!(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})

      response = build_response(~s({"name": "Alice"}))

      assert {:ok, %Response{object: %{"name" => "Alice"}}} =
               ResponseValidator.validate(response, schema, false)
    end
  end

  describe "validate/3 error cases" do
    test "returns error when text is nil" do
      schema = normalize!(Zoi.map(%{name: Zoi.string()}, coerce: true))
      response = build_response(nil)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when text is nil with validation disabled" do
      schema = normalize!(Zoi.map(%{name: Zoi.string()}, coerce: true))
      response = build_response(nil)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, false)
    end

    test "returns error when JSON is invalid" do
      schema = normalize!(Zoi.map(%{name: Zoi.string()}, coerce: true))
      response = build_response("not json at all")

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when JSON is invalid with validation disabled" do
      schema = normalize!(Zoi.map(%{name: Zoi.string()}, coerce: true))
      response = build_response("{broken")

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, false)
    end
  end
end
