defmodule Sycophant.RecordingCase do
  @moduledoc """
  ExUnit case template for tests that use recorded HTTP fixtures.

  Recording tests are excluded by default. Run them with:

      mix test.recording                              # all recorded models
      RECORD=true mix test.recording                  # record missing fixtures
      RECORD=true RECORD_MODELS=amazon_bedrock mix test.recording  # record specific models

  ### Explicit recording name

      @tag recording: "openai/gpt-4o/generate_text_basic"
      test "generates text" do
        # The middleware will replay the fixture automatically
      end

  ### Parameterized with auto-derived name

  When used with `parameterize` and a `fixture_prefix` param, tag
  the test with `recording_prefix: true` and the recording name
  is built from `fixture_prefix/slugified_test_name`.

      @models Sycophant.RecordingCase.test_models()
      use Sycophant.RecordingCase, async: true, parameterize: @models

      @tag recording_prefix: true
      test "generates text", %{model: model} do
        ...
      end

  ## Model Filtering

  Set `RECORD_MODELS` to a comma-separated list of model specs to
  only record fixtures for specific models:

      RECORD=true RECORD_MODELS=anthropic:claude-haiku-4-5-20251001 mix test.recording

  Supports prefix matching: `RECORD_MODELS=anthropic` matches all
  anthropic models. When unset, all configured test models are used.
  """

  use ExUnit.CaseTemplate

  @doc """
  Returns the filtered list of test model parameterization maps.

  Reads `:test_models` from app config (list of maps with `:model` key
  and capability flags like `:structured_output`). Filters by:

  - `RECORD_MODELS` env var (comma-separated, prefix matching)
  - `require` option to filter by capability flags

  ## Examples

      Sycophant.RecordingCase.test_models()
      Sycophant.RecordingCase.test_models(require: :structured_output)
  """
  def test_models(opts \\ []) do
    all_entries = Application.get_env(:sycophant, :test_models, [])

    entries =
      all_entries
      |> filter_by_capability(opts[:require])
      |> filter_by_env()

    for entry <- entries do
      model = entry.model

      %{model: model, fixture_prefix: String.replace(model, ":", "/")}
      |> maybe_put_flag(entry, :reasoning)
      |> maybe_put_flag(entry, :structured_output)
    end
  end

  defp maybe_put_flag(map, entry, key) do
    if Map.get(entry, key), do: Map.put(map, key, true), else: map
  end

  @doc """
  Returns the filtered list of test embedding model parameterization maps.

  Reads `:test_embedding_models` from app config. Filters by `RECORD_MODELS`
  env var the same way as `test_models/1`.
  """
  def test_embedding_models do
    all_entries = Application.get_env(:sycophant, :test_embedding_models, [])

    entries = filter_by_env(all_entries)

    for entry <- entries do
      model = entry.model
      %{model: model, fixture_prefix: String.replace(model, ":", "/")}
    end
  end

  defp filter_by_capability(entries, nil), do: entries

  defp filter_by_capability(entries, capability) do
    Enum.filter(entries, &Map.get(&1, capability, false))
  end

  defp filter_by_env(entries) do
    case System.get_env("RECORD_MODELS") do
      nil ->
        entries

      "" ->
        entries

      filter_str ->
        filters = filter_str |> String.split(",") |> Enum.map(&String.trim/1)

        Enum.filter(entries, fn entry ->
          Enum.any?(filters, &String.starts_with?(entry.model, &1))
        end)
    end
  end

  using do
    quote do
      @moduletag :recording

      defp recording_opts(opts) do
        if System.get_env("RECORD") in ["true", "force"] do
          opts
        else
          Keyword.put_new(opts, :credentials, %{
            api_key: "recorded",
            access_key_id: "recorded",
            secret_access_key: "recorded",
            region: "us-east-1"
          })
        end
      end
    end
  end

  setup context do
    recording = resolve_recording(context)

    if recording do
      Sycophant.Tesla.RecorderMiddleware.set_recording(recording)
      on_exit(fn -> Sycophant.Tesla.RecorderMiddleware.clear_recording() end)
    end

    :ok
  end

  defp resolve_recording(%{recording: name}) when is_binary(name), do: name

  defp resolve_recording(%{recording_prefix: true, fixture_prefix: prefix} = context) do
    slug =
      context.test
      |> Atom.to_string()
      |> String.replace(~r/^test\s+/, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim_trailing("_")

    "#{prefix}/#{slug}"
  end

  defp resolve_recording(_), do: nil
end
