defmodule Sycophant.ResponseValidatorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Context
  alias Sycophant.Response
  alias Sycophant.ResponseValidator

  defp build_response(text) do
    %Response{
      text: text,
      context: %Context{messages: [], model: "test"}
    }
  end

  describe "validate/3 with validation enabled" do
    test "parses JSON and validates against Zoi schema" do
      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)
      response = build_response(~s({"name": "Alice", "age": 30}))

      assert {:ok, %Response{object: %{name: "Alice", age: 30}}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when JSON is invalid" do
      schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
      response = build_response("not json at all")

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when schema validation fails" do
      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)
      response = build_response(~s({"name": 123}))

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end

    test "returns error when text is nil" do
      schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
      response = build_response(nil)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, true)
    end
  end

  describe "validate/3 with validation disabled" do
    test "skips schema validation and returns raw decoded JSON" do
      schema = Zoi.map(%{name: Zoi.string(), age: Zoi.integer()}, coerce: true)
      response = build_response(~s({"name": "Alice", "age": 30}))

      assert {:ok, %Response{object: %{"name" => "Alice", "age" => 30}}} =
               ResponseValidator.validate(response, schema, false)
    end

    test "returns error when text is nil even with validation disabled" do
      schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
      response = build_response(nil)

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, false)
    end

    test "returns error when JSON is invalid even with validation disabled" do
      schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
      response = build_response("{broken")

      assert {:error, %Sycophant.Error.Invalid.InvalidResponse{}} =
               ResponseValidator.validate(response, schema, false)
    end
  end
end
