defmodule Sycophant.OAuthFailedTest do
  use ExUnit.Case, async: true

  alias Sycophant.Error.Invalid.OAuthFailed

  test "renders a reason without an optional code" do
    assert Exception.message(OAuthFailed.exception(reason: "connection closed")) ==
             "OAuth failed: connection closed"
  end

  test "renders string and exception reasons" do
    assert Exception.message(OAuthFailed.exception(reason: "x", code: "invalid_grant")) ==
             "OAuth failed (invalid_grant): x"

    assert Exception.message(
             OAuthFailed.exception(reason: ArgumentError.exception("bad token"), code: nil)
           ) == "OAuth failed: bad token"
  end
end
