defmodule Sycophant.WireProtocol.AnthropicThinking do
  @moduledoc """
  Claude thinking request fields, shared by the Anthropic Messages and Bedrock
  Converse wires.

  The thinking type follows the resolved model's LLMDB `thinking.types`:

    * models that accept `enabled` thinking (Claude 4.6 and earlier) get a
      fixed `budget_tokens` per `:reasoning_effort` level,
    * models that only take `adaptive` thinking (Claude Opus 4.7 and later)
      get `adaptive` thinking plus `output_config.effort`, since they reject
      `budget_tokens`,
    * `:none` sends `disabled` thinking, or nothing for models that cannot
      turn thinking off.

  Models without thinking metadata are treated as accepting every type.

  `:reasoning_summary` sets `thinking.display`: `:none` sends `"omitted"` and
  any other value `"summarized"`. Opus 4.7 and later default to `"omitted"`,
  which returns thinking blocks with empty text. Unset keeps the model's
  default.
  """

  alias Sycophant.Request

  @budgets %{
    minimal: 1024,
    low: 1024,
    medium: 4096,
    high: 16_384,
    xhigh: 32_768,
    max: 32_768
  }

  @efforts %{
    minimal: "low",
    low: "low",
    medium: "medium",
    high: "high",
    xhigh: "xhigh",
    max: "max"
  }

  @doc """
  Returns the `"thinking"` and `"output_config"` fields for `request`, or an
  empty map when no thinking configuration applies.
  """
  @spec fields(Request.t()) :: %{optional(String.t()) => map()}
  def fields(%Request{params: %{reasoning_effort: :none}} = request) do
    if supports?(request, "disabled"),
      do: %{"thinking" => %{"type" => "disabled"}},
      else: %{}
  end

  def fields(%Request{params: %{reasoning_effort: level} = params} = request)
      when is_map_key(@budgets, level) do
    summary = params[:reasoning_summary]

    if supports?(request, "enabled") do
      thinking = %{"type" => "enabled", "budget_tokens" => Map.fetch!(@budgets, level)}
      %{"thinking" => put_display(thinking, summary)}
    else
      %{
        "thinking" => put_display(%{"type" => "adaptive"}, summary),
        "output_config" => %{"effort" => Map.fetch!(@efforts, level)}
      }
    end
  end

  def fields(_request), do: %{}

  defp supports?(%Request{resolved_model: model}, type) do
    case model do
      %{capabilities: %{reasoning: %{thinking: %{types: types}}}} when is_list(types) ->
        type in types

      _unknown ->
        true
    end
  end

  defp put_display(thinking, nil), do: thinking
  defp put_display(thinking, :none), do: Map.put(thinking, "display", "omitted")
  defp put_display(thinking, _summary), do: Map.put(thinking, "display", "summarized")
end
