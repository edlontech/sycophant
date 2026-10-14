defmodule Sycophant.OAuth.Session do
  @moduledoc "Serializable state for an in-progress OAuth authorization."
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("OAuthSession") |> Zoi.default("OAuthSession"),
            state: Zoi.string(),
            nonce: Zoi.string(),
            code_verifier: Zoi.string(),
            redirect_uri: Zoi.string(),
            client_id: Zoi.optional(Zoi.string()),
            created_at: Zoi.datetime(coerce: true)
end

defimpl Inspect, for: Sycophant.OAuth.Session do
  import Inspect.Algebra

  def inspect(session, opts) do
    fields = session |> Map.from_struct() |> Map.put(:code_verifier, "[REDACTED]")
    concat(["#Sycophant.OAuth.Session<", to_doc(fields, opts), ">"])
  end
end
