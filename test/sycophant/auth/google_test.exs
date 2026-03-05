defmodule Sycophant.Auth.GoogleTest do
  use ExUnit.Case, async: true

  alias Sycophant.Auth.Google

  test "produces x-goog-api-key header middleware" do
    assert [{Tesla.Middleware.Headers, [{"x-goog-api-key", "test-key"}]}] =
             Google.middlewares(%{api_key: "test-key"})
  end

  test "returns empty list when no api_key" do
    assert [] = Google.middlewares(%{})
  end
end
