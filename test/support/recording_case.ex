defmodule Sycophant.RecordingCase do
  @moduledoc """
  ExUnit case template for tests that use recorded HTTP fixtures.

  Supports two modes:

  ### Explicit recording name

      @tag recording: "openai/gpt-4o/generate_text_basic"
      test "generates text" do
        # The middleware will replay the fixture automatically
      end

  ### Parameterized with auto-derived name

  When used with `parameterize` and a `fixture_prefix` param, tag
  the test with `recording_prefix: true` and the recording name
  is built from `fixture_prefix/slugified_test_name`.

      use Sycophant.RecordingCase,
        async: true,
        parameterize: for model <- ["openai:gpt-4o-mini"] do
          %{model: model, fixture_prefix: "openai/gpt-4o-mini"}
        end

      @tag recording_prefix: true
      test "generates text", %{model: model} do
        ...
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      defp recording_opts(opts) do
        if System.get_env("RECORD") == "true" do
          opts
        else
          Keyword.put_new(opts, :credentials, %{api_key: "recorded"})
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

  defp resolve_recording(%{recording: name}), do: name

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
