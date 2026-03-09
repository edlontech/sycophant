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
    * `:record` - when `true`, forces recording (same as `RECORD=force`).
      Defaults to checking the `RECORD` env var.

  ## Environment

    * `RECORD=true`  - records only missing fixtures, replays existing ones
    * `RECORD=force` - re-records all fixtures regardless of existence
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

  @doc "Sets the recording name in the process dictionary and resets the call counter."
  @spec set_recording(String.t()) :: term()
  def set_recording(name) do
    Process.put(:sycophant_recording_seq, 0)
    Process.put(:sycophant_recording, name)
  end

  @doc "Gets the current recording name from the process dictionary."
  @spec get_recording() :: String.t() | nil
  def get_recording, do: Process.get(:sycophant_recording)

  @doc "Clears the recording name from the process dictionary."
  @spec clear_recording() :: term()
  def clear_recording do
    Process.delete(:sycophant_recording_seq)
    Process.delete(:sycophant_recording)
  end

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
      %URI{host: host} when is_binary(host) -> sanitize_host(host)
      _ -> "unknown"
    end
  end

  defp sanitize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) ->
        URI.to_string(%{uri | host: sanitize_host(host)})

      _ ->
        url
    end
  end

  @provider_domains %{
    ".openai.azure.com" => "azure",
    ".cognitiveservices.azure.com" => "azure",
    ".services.ai.azure.com" => "azure"
  }

  defp sanitize_host(host) do
    case Enum.find(@provider_domains, fn {suffix, _} -> String.ends_with?(host, suffix) end) do
      {_, provider} -> provider
      nil -> host
    end
  end

  defp handle_recording(env, next, name, opts) do
    seq_name = sequenced_name(name)

    case record_mode?(opts) do
      :record ->
        if fixture_exists?(seq_name, opts) do
          replay(env, seq_name, opts)
        else
          record(env, next, seq_name, opts)
        end

      :force ->
        record(env, next, seq_name, opts)

      :replay ->
        replay(env, seq_name, opts)
    end
  end

  defp sequenced_name(name) do
    seq = Process.get(:sycophant_recording_seq, 0) + 1
    Process.put(:sycophant_recording_seq, seq)

    case seq do
      1 -> name
      n -> "#{name}_#{n}"
    end
  end

  defp record_mode?(opts) do
    case Keyword.get(opts, :record) do
      true -> :force
      false -> :replay
      mode when mode in [:record, :force, :replay] -> mode
      nil -> record_mode_from_env()
    end
  end

  defp record_mode_from_env do
    case System.get_env("RECORD") do
      "true" -> :record
      "force" -> :force
      _ -> :replay
    end
  end

  defp fixture_exists?(name, opts) do
    name |> fixture_path(opts) |> File.exists?()
  end

  defp record(env, next, name, opts) do
    case Tesla.run(env, next) do
      {:ok, response_env} ->
        {response_env, streaming?} = maybe_collect_stream(response_env)

        if response_env.status < 400 do
          write_fixture(name, env, response_env, streaming?, opts)
        end

        {:ok, response_env}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_collect_stream(%Tesla.Env{body: body} = env)
       when is_binary(body) or (is_map(body) and not is_struct(body)) or is_nil(body) do
    {env, false}
  end

  defp maybe_collect_stream(%Tesla.Env{body: stream} = env) do
    collected = Enum.reduce(stream, <<>>, fn chunk, acc -> acc <> chunk end)
    {%{env | body: collected}, true}
  end

  defp replay(env, name, opts) do
    case read_fixture(name, opts) do
      {:ok, fixture} ->
        {:ok, fixture_to_env(env, fixture)}

      {:error, reason} ->
        {:error,
         "Fixture not found for recording '#{name}': #{inspect(reason)}. Run with RECORD=true to record missing fixtures."}
    end
  end

  defp write_fixture(name, request_env, response_env, streaming?, opts) do
    metadata =
      then(
        %{
          "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "sycophant_version" => Application.spec(:sycophant, :vsn) |> to_string(),
          "model" => extract_model(request_env.body),
          "provider" => extract_provider(request_env.url)
        },
        fn m -> if streaming?, do: Map.put(m, "streaming", true), else: m end
      )

    {response_body, binary_stream?} =
      cond do
        not streaming? ->
          {safe_decode(response_env.body), false}

        String.valid?(response_env.body) ->
          {response_env.body, false}

        true ->
          {Base.encode64(response_env.body), true}
      end

    metadata =
      if binary_stream?,
        do: Map.put(metadata, "binary_streaming", true),
        else: metadata

    fixture = %{
      "metadata" => metadata,
      "request" => %{
        "method" => to_string(request_env.method),
        "url" => sanitize_url(request_env.url),
        "headers" => redact_headers(request_env.headers),
        "body" => safe_decode(request_env.body)
      },
      "response" => %{
        "status" => response_env.status,
        "headers" => redact_headers(response_env.headers),
        "body" => response_body
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
    streaming? = get_in(fixture, ["metadata", "streaming"]) == true
    binary_streaming? = get_in(fixture, ["metadata", "binary_streaming"]) == true

    body =
      cond do
        binary_streaming? ->
          [Base.decode64!(response["body"])]

        streaming? ->
          response["body"]

        true ->
          JSON.encode!(response["body"])
      end

    %Tesla.Env{
      request_env
      | status: response["status"],
        headers: decode_headers(response["headers"]),
        body: body
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
    "x-goog-api-key",
    "x-amz-security-token",
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
