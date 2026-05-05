#!/usr/bin/env elixir
# Performs the GitHub device flow against the VS Code Copilot OAuth App
# (client_id Iv1.b507a08c87ecfe98) and prints a gho_... access token that
# is accepted by https://api.github.com/copilot_internal/v2/token.
#
# Usage: mix run scripts/copilot_login.exs
#        Then export the printed token: export GITHUB_TOKEN=gho_...

Mix.install([{:req, "~> 0.5"}])

client_id = "Iv1.b507a08c87ecfe98"
scope = "read:user"

IO.puts("Requesting device code...")

%{status: 200, body: device} =
  Req.post!("https://github.com/login/device/code",
    headers: [{"accept", "application/json"}],
    form: [client_id: client_id, scope: scope]
  )

IO.puts("")
IO.puts("Open: #{device["verification_uri"]}")
IO.puts("Code: #{device["user_code"]}")
IO.puts("")
IO.puts("Waiting for approval (polling every #{device["interval"]}s)...")

interval_ms = device["interval"] * 1_000

token =
  Stream.repeatedly(fn ->
    Process.sleep(interval_ms)

    Req.post!("https://github.com/login/oauth/access_token",
      headers: [{"accept", "application/json"}],
      form: [
        client_id: client_id,
        device_code: device["device_code"],
        grant_type: "urn:ietf:params:oauth:grant-type:device_code"
      ]
    ).body
  end)
  |> Enum.reduce_while(nil, fn body, _ ->
    case body do
      %{"access_token" => token} ->
        {:halt, token}

      %{"error" => "authorization_pending"} ->
        IO.write(".")
        {:cont, nil}

      %{"error" => "slow_down"} ->
        IO.write("s")
        {:cont, nil}

      %{"error" => err} ->
        IO.puts("\nGitHub returned error: #{err}")
        {:halt, nil}
    end
  end)

IO.puts("")

case token do
  nil ->
    System.halt(1)

  token ->
    IO.puts("Token: #{token}")
    IO.puts("")
    IO.puts("Verifying with copilot_internal/v2/token...")

    verify =
      Req.get!("https://api.github.com/copilot_internal/v2/token",
        headers: [
          {"authorization", "token #{token}"},
          {"accept", "application/json"},
          {"user-agent", "GitHubCopilotChat/0.22.0"},
          {"editor-version", "vscode/1.95.0"},
          {"editor-plugin-version", "copilot-chat/0.22.0"}
        ]
      )

    case verify.status do
      200 ->
        IO.puts("OK. Token works at copilot_internal/v2/token.")
        IO.puts("")
        IO.puts("To use:  export GITHUB_TOKEN=#{token}")
        IO.puts("In fish: set -lx GITHUB_TOKEN #{token}")

      status ->
        IO.puts("Verification returned #{status}: #{inspect(verify.body)}")
        System.halt(1)
    end
end
