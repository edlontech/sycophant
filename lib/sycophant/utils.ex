defmodule Sycophant.Utils do
  @moduledoc false

  @doc """
  Converts a string to an existing atom without raising.

  Returns `nil` and atoms unchanged. A string with no matching atom is
  returned as-is, so callers can report it instead of crashing.

      iex> Sycophant.Utils.safe_to_existing_atom("ok")
      :ok

      iex> Sycophant.Utils.safe_to_existing_atom("sycophant_no_such_atom_xyz")
      "sycophant_no_such_atom_xyz"
  """
  @spec safe_to_existing_atom(nil | atom() | String.t()) :: nil | atom() | String.t()
  def safe_to_existing_atom(nil), do: nil
  def safe_to_existing_atom(value) when is_atom(value), do: value

  def safe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
