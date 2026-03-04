defmodule Sycophant.Tesla.RecorderMiddleware do
  @moduledoc """
  Tesla middleware for recording and replaying HTTP exchanges in tests.

  In replay mode (default), reads a fixture file and returns the stored response.
  In record mode, passes through to the real API, captures the exchange, and writes it to disk.

  The middleware is a no-op when no recording tag is set in the process dictionary,
  so it is safe to always include in the test middleware stack.

  ## Usage

  Set the recording name via the process dictionary before making a request:

      Sycophant.Tesla.RecorderMiddleware.set_recording("openai/gpt-4o/basic")

  ## Options

    * `:fixtures_path` - directory where fixture files are stored.
      Defaults to `"test/fixtures/recordings"`.
    * `:record` - when `true`, records real API responses to disk.
      Defaults to checking `System.get_env("RECORD") == "true"`.
  """

  @behaviour Tesla.Middleware

  @default_fixtures_path "priv/fixtures/recordings"

  @impl Tesla.Middleware
  def call(env, next, opts) do
    case get_recording() do
      nil -> Tesla.run(env, next)
      name -> handle_recording(env, next, name, opts)
    end
  end

  @doc "Sets the recording name in the process dictionary."
  @spec set_recording(String.t()) :: term()
  def set_recording(name), do: Process.put(:sycophant_recording, name)

  @doc "Gets the current recording name from the process dictionary."
  @spec get_recording() :: String.t() | nil
  def get_recording, do: Process.get(:sycophant_recording)

  @doc "Clears the recording name from the process dictionary."
  @spec clear_recording() :: term()
  def clear_recording, do: Process.delete(:sycophant_recording)

  defp extract_model(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"model" => model}} -> model
      _ -> "unknown"
    end
  end

  defp extract_model(%{"model" => model}), do: model
  defp extract_model(_), do: "unknown"

  defp extract_provider(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown"
    end
  end

  defp extract_provider(_), do: "unknown"

  defp handle_recording(env, next, name, opts) do
    if record_mode?(opts) do
      record(env, next, name, opts)
    else
      replay(env, name, opts)
    end
  end

  defp record_mode?(opts) do
    Keyword.get(opts, :record, System.get_env("RECORD") == "true")
  end

  defp record(env, next, name, opts) do
    case Tesla.run(env, next) do
      {:ok, response_env} ->
        write_fixture(name, env, response_env, opts)
        {:ok, response_env}

      {:error, _} = error ->
        error
    end
  end

  defp replay(env, name, opts) do
    case read_fixture(name, opts) do
      {:ok, fixture} ->
        {:ok, fixture_to_env(env, fixture)}

      {:error, reason} ->
        {:error,
         "Fixture not found for recording '#{name}': #{inspect(reason)}. Run with RECORD=true to create it."}
    end
  end

  defp write_fixture(name, request_env, response_env, opts) do
    fixture = %{
      "metadata" => %{
        "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "sycophant_version" => Application.spec(:sycophant, :vsn) |> to_string(),
        "model" => extract_model(request_env.body),
        "provider" => extract_provider(request_env.url)
      },
      "request" => %{
        "method" => to_string(request_env.method),
        "url" => request_env.url,
        "headers" => redact_headers(request_env.headers),
        "body" => safe_decode(request_env.body)
      },
      "response" => %{
        "status" => response_env.status,
        "headers" => redact_headers(response_env.headers),
        "body" => safe_decode(response_env.body)
      }
    }

    path = fixture_path(name, opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(fixture, pretty: true))
  end

  defp read_fixture(name, opts) do
    path = fixture_path(name, opts)

    with {:ok, content} <- File.read(path) do
      JSON.decode(content)
    end
  end

  defp fixture_to_env(%Tesla.Env{} = request_env, fixture) do
    response = fixture["response"]

    %Tesla.Env{
      request_env
      | status: response["status"],
        headers: decode_headers(response["headers"]),
        body: JSON.encode!(response["body"])
    }
  end

  defp fixture_path(name, opts) do
    base = Keyword.get(opts, :fixtures_path, @default_fixtures_path)
    Path.join([base, "#{name}.json"])
  end

  @sensitive_headers [
    "authorization",
    "x-api-key",
    "api-key",
    "openai-organization",
    "openai-project",
    "set-cookie"
  ]

  defp redact_headers(headers) do
    Enum.map(headers, fn
      {key, value} -> redact_header(key, value)
      [key, value] -> redact_header(key, value)
    end)
  end

  defp redact_header(key, value) do
    if String.downcase(key) in @sensitive_headers do
      [key, "[REDACTED]"]
    else
      [key, value]
    end
  end

  defp decode_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      [key, value] -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp safe_decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp safe_decode(body) when is_map(body), do: body
  defp safe_decode(body), do: body
end
