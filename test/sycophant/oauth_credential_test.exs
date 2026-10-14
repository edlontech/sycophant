defmodule Sycophant.OAuth.CredentialTest do
  use ExUnit.Case, async: true

  alias Sycophant.OAuth.Credential
  alias Sycophant.Serializable.Decoder

  setup do
    credential = %Credential{
      access_token: "access",
      refresh_token: "refresh",
      id_token: "id",
      token_type: "Bearer",
      client_id: "dynamic_agent_client",
      issuer: "https://auth.openai.com",
      subject: "user-id",
      scopes: [],
      obtained_at: ~U[2026-01-01 12:00:00.123456Z],
      expires_at: ~U[2026-01-01 13:00:00.123456Z]
    }

    %{credential: credential}
  end

  test "round-trips tokens, timestamps, and optional email through JSON", %{credential: base} do
    for {email, scopes} <- [{nil, []}, {"user@example.com", ["openid", "offline_access"]}] do
      credential = %{base | email: email, scopes: scopes}
      assert credential == credential |> Decoder.encode() |> Decoder.decode()
    end
  end

  test "expiry includes the refresh margin and its boundary", %{credential: base} do
    now = ~U[2026-01-01 12:00:00Z]
    Mimic.stub(DateTime, :utc_now, fn -> now end)

    refute Credential.expired?(%{base | expires_at: DateTime.add(now, 600)})
    assert Credential.expired?(%{base | expires_at: DateTime.add(now, 120)})
    assert Credential.expired?(%{base | expires_at: DateTime.add(now, -1)})
    assert Credential.expired?(%{base | expires_at: DateTime.add(now, 180)})
    refute Credential.expired?(%{base | expires_at: DateTime.add(now, 120)}, 0)
    assert Credential.expired?(%{base | expires_at: now}, 0)
  end

  test "inspection redacts all tokens and preserves identity", %{credential: base} do
    credential = %{
      base
      | access_token: "secret-access",
        refresh_token: "secret-refresh",
        id_token: "secret-id",
        subject: "public-subject"
    }

    rendered = inspect(credential)

    for token <- ["secret-access", "secret-refresh", "secret-id"], do: refute(rendered =~ token)
    assert rendered =~ "[REDACTED]"
    assert rendered =~ "public-subject"
  end
end
