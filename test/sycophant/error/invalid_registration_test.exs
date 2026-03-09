defmodule Sycophant.Error.Invalid.InvalidRegistrationTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.InvalidRegistration

  test "message includes module and behaviour" do
    error = InvalidRegistration.exception(module: MyApp.Fake, behaviour: Sycophant.Auth)
    assert Exception.message(error) =~ "MyApp.Fake"
    assert Exception.message(error) =~ "Sycophant.Auth"
  end
end
