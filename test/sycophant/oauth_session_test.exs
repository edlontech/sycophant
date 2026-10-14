defmodule Sycophant.OAuth.SessionTest do
  use ExUnit.Case, async: true

  alias Sycophant.OAuth.Session
  alias Sycophant.Serializable.Decoder

  test "inspection redacts the PKCE verifier but preserves public fields" do
    session = %Session{
      state: "public-state",
      code_verifier: "secret-verifier",
      nonce: "nonce",
      redirect_uri: "http://127.0.0.1:4000/callback",
      created_at: ~U[2026-01-01 12:00:00Z]
    }

    rendered = inspect(session)

    refute rendered =~ "secret-verifier"
    assert rendered =~ "[REDACTED]"
    assert rendered =~ "public-state"
  end

  test "round-trips session timestamps and optional client ID through JSON" do
    for client_id <- [nil, "dynamic_agent_client"] do
      session =
        struct!(Session,
          state: "state",
          nonce: "nonce",
          code_verifier: "secret-verifier",
          redirect_uri: "http://127.0.0.1:4000/callback",
          client_id: client_id,
          created_at: ~U[2026-01-01 12:00:00.123456Z]
        )

      assert session == session |> Decoder.encode() |> Decoder.decode()
    end
  end
end
