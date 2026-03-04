defmodule Sycophant.ErrorTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error
  alias Sycophant.Error.Invalid
  alias Sycophant.Error.Provider
  alias Sycophant.Error.Unknown

  describe "Invalid errors" do
    test "MissingModel constructs and has correct class" do
      error = Invalid.MissingModel.exception([])
      assert error.class == :invalid
      assert Exception.message(error) =~ "No model specified"
    end

    test "MissingCredentials carries provider and interpolates message" do
      error = Invalid.MissingCredentials.exception(provider: :openai)
      assert error.class == :invalid
      assert error.provider == :openai
      assert Exception.message(error) =~ "openai"
    end

    test "InvalidParams carries errors and includes details in message" do
      error = Invalid.InvalidParams.exception(errors: ["bad temp", "invalid top_p"])
      assert error.errors == ["bad temp", "invalid top_p"]
      assert Exception.message(error) =~ "bad temp"
      assert Exception.message(error) =~ "invalid top_p"
    end

    test "InvalidSchema carries errors, target, and context" do
      error =
        Invalid.InvalidSchema.exception(
          errors: ["not a schema"],
          target: :tools,
          context: :structured_output
        )

      assert error.errors == ["not a schema"]
      assert error.target == :tools
      assert error.context == :structured_output
      assert Exception.message(error) =~ "not a schema"
      assert Exception.message(error) =~ "tools"
    end
  end

  describe "Provider errors" do
    test "RateLimited carries retry_after and interpolates message" do
      error = Provider.RateLimited.exception(retry_after: 30)
      assert error.class == :provider
      assert error.retry_after == 30
      assert Exception.message(error) =~ "30"
    end

    test "AuthenticationFailed carries status and body with interpolated message" do
      error = Provider.AuthenticationFailed.exception(status: 401, body: "unauthorized")
      assert error.status == 401
      assert Exception.message(error) =~ "401"
      assert Exception.message(error) =~ "unauthorized"
    end

    test "ModelNotFound carries model name and interpolates message" do
      error = Provider.ModelNotFound.exception(model: "gpt-5")
      assert error.model == "gpt-5"
      assert Exception.message(error) =~ "gpt-5"
    end

    test "ContentFiltered carries reason and interpolates message" do
      error = Provider.ContentFiltered.exception(reason: "safety")
      assert error.reason == "safety"
      assert Exception.message(error) =~ "safety"
    end

    test "ServerError carries status and body with interpolated message" do
      error = Provider.ServerError.exception(status: 500, body: "internal")
      assert error.status == 500
      assert Exception.message(error) =~ "500"
      assert Exception.message(error) =~ "internal"
    end

    test "ResponseInvalid carries errors and raw response with details in message" do
      error = Provider.ResponseInvalid.exception(errors: ["mismatch"], raw: %{})
      assert error.errors == ["mismatch"]
      assert error.raw == %{}
      assert Exception.message(error) =~ "mismatch"
    end
  end

  describe "Unknown errors" do
    test "Unknown wraps arbitrary errors" do
      error = Unknown.Unknown.exception(error: "something broke")
      assert error.class == :unknown
      assert Exception.message(error) == "something broke"
    end

    test "Unknown inspects non-binary errors" do
      error = Unknown.Unknown.exception(error: {:some, :tuple})
      assert Exception.message(error) =~ "Unknown error"
      assert Exception.message(error) =~ "some"
    end
  end

  describe "pattern matching" do
    test "matches at class level" do
      error = Invalid.MissingModel.exception([])
      assert %Invalid.MissingModel{class: :invalid} = error
    end

    test "matches specific error with fields" do
      error = Provider.RateLimited.exception(retry_after: 60)
      assert %Provider.RateLimited{retry_after: 60} = error
    end
  end

  describe "Splode root" do
    test "to_error converts unknown exceptions" do
      result = Error.to_error("something unexpected")
      assert result.class == :unknown
    end
  end
end
