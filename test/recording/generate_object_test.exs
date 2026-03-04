defmodule Sycophant.Recording.GenerateObjectTest do
  @models (for model <- Application.compile_env(:sycophant, :structured_output_models, []) do
             %{model: model, fixture_prefix: String.replace(model, ":", "/")}
           end)

  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message

  @tag recording_prefix: true
  test "generates structured object", %{model: model} do
    schema =
      Zoi.map(
        %{
          name: Zoi.string(),
          age: Zoi.integer(),
          hobbies: Zoi.list(Zoi.string())
        },
        coerce: true
      )

    messages = [
      Message.user(
        "Generate a fictional person with name, age, and 2-3 hobbies. Return only JSON."
      )
    ]

    {:ok, response} =
      Sycophant.generate_object(messages, schema, recording_opts(model: model))

    assert is_map(response.object)
    assert is_binary(response.object[:name])
    assert is_integer(response.object[:age])
    assert is_list(response.object[:hobbies])
  end
end
