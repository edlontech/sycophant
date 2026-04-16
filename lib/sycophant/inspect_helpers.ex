defmodule Sycophant.InspectHelpers do
  @moduledoc false

  @default_limit 50

  @doc false
  @spec truncate(String.t() | nil, non_neg_integer()) :: String.t() | nil
  def truncate(str, limit \\ @default_limit)
  def truncate(nil, _limit), do: nil

  def truncate(str, limit) when is_binary(str) do
    sliced = String.slice(str, 0, limit)
    if sliced == str, do: str, else: sliced <> "..."
  end

  @doc false
  @spec truncate_inspect(term(), non_neg_integer()) :: String.t() | nil
  def truncate_inspect(term, limit \\ @default_limit)
  def truncate_inspect(nil, _limit), do: nil

  def truncate_inspect(term, limit) do
    term |> Kernel.inspect() |> truncate(limit)
  end

  @doc false
  @spec redact(term()) :: String.t() | nil
  def redact(nil), do: nil
  def redact(_), do: "**REDACTED**"

  @doc false
  @spec fn_label(function() | {term(), function()} | nil) :: String.t() | nil
  def fn_label(nil), do: nil

  def fn_label({_acc, fun}) when is_function(fun), do: "{acc, fn/2}"

  def fn_label(fun) when is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    "fn/#{arity}"
  end
end
