defmodule Sycophant.AuthRequestConstraintsTest do
  use ExUnit.Case, async: false

  alias Sycophant.Auth
  alias Sycophant.Auth.RequestConstraints

  defmodule ConstrainedAuth do
    @behaviour Sycophant.Auth

    @impl true
    def middlewares(_credentials), do: []

    @impl true
    def request_constraints(%{mode: :subscription}, %{model_id: "test-model"}) do
      %RequestConstraints{
        unsupported_params: [:temperature],
        forced_params: %{store: false},
        require_stream: true
      }
    end
  end

  test "registered strategies receive credentials and model metadata" do
    Sycophant.Registry.register_auth!(:task_2_constrained_auth, ConstrainedAuth)

    assert %RequestConstraints{
             unsupported_params: [:temperature],
             forced_params: %{store: false},
             require_stream: true
           } =
             Auth.request_constraints_for(
               :task_2_constrained_auth,
               %{mode: :subscription},
               %{model_id: "test-model"}
             )
  end

  test "providers without the optional callback return empty constraints" do
    for provider <- [:openai, :nonexistent, :anthropic] do
      constraints = Auth.request_constraints_for(provider, %{}, %{})
      assert constraints.__struct__ == Sycophant.Auth.RequestConstraints
      assert constraints.unsupported_params == []
      assert constraints.forced_params == %{}
      assert constraints.require_stream == false
    end
  end
end
