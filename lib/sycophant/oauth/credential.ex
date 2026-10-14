defmodule Sycophant.OAuth.Credential do
  @moduledoc "Serializable OAuth tokens and identity metadata. Store securely."
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("OAuthCredential") |> Zoi.default("OAuthCredential"),
            access_token: Zoi.string(),
            refresh_token: Zoi.string(),
            id_token: Zoi.string(),
            token_type: Zoi.string(),
            client_id: Zoi.string(),
            issuer: Zoi.string(),
            subject: Zoi.string(),
            email: Zoi.optional(Zoi.string()),
            scopes: Zoi.list(Zoi.string()) |> Zoi.default([]),
            expires_at: Zoi.datetime(coerce: true),
            obtained_at: Zoi.datetime(coerce: true)

  @doc "Whether the credential expires within the margin (180 seconds by default)."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, margin_seconds \\ 180)
      when is_integer(margin_seconds) and margin_seconds >= 0 do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), margin_seconds)) != :gt
  end
end

defimpl Inspect, for: Sycophant.OAuth.Credential do
  import Inspect.Algebra

  def inspect(credential, opts) do
    fields =
      credential
      |> Map.from_struct()
      |> Map.merge(%{
        access_token: "[REDACTED]",
        refresh_token: "[REDACTED]",
        id_token: "[REDACTED]"
      })

    concat(["#Sycophant.OAuth.Credential<", to_doc(fields, opts), ">"])
  end
end
