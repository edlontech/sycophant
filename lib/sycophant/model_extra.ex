defmodule Sycophant.ModelExtra do
  @moduledoc """
  Key-agnostic reads of `LLMDB.Model` and `LLMDB.Provider` `:extra` metadata.

  LLMDB treats `:extra` as provider-owned opaque data: snapshot-loaded entries
  keep their JSON string keys, while entries built in-process (tests, custom
  registries) commonly use atom keys. These helpers accept either shape.

  ## Examples

      iex> Sycophant.ModelExtra.get(%{"temperature" => false}, :temperature)
      false

      iex> Sycophant.ModelExtra.get(%{temperature: false}, :temperature)
      false

      iex> Sycophant.ModelExtra.get(%{}, :temperature, :missing)
      :missing

      iex> Sycophant.ModelExtra.get_path(%{"wire" => %{protocol: "openai_chat"}}, [:wire, :protocol])
      "openai_chat"
  """

  @doc """
  Reads `key` from `extra`, trying the atom key before its string form.

  Returns `default` when `extra` is not a map or the key is absent.
  """
  @spec get(term(), atom(), term()) :: term()
  def get(extra, key, default \\ nil)

  def get(extra, key, default) when is_map(extra) and is_atom(key) do
    case extra do
      %{^key => value} -> value
      _ -> Map.get(extra, Atom.to_string(key), default)
    end
  end

  def get(_extra, _key, default), do: default

  @doc """
  Walks a nested `path` through `extra`, accepting either key form at each level.

  Returns `nil` as soon as a segment is missing.
  """
  @spec get_path(term(), [atom()]) :: term()
  def get_path(extra, path) when is_list(path) do
    Enum.reduce(path, extra, &get(&2, &1))
  end
end
