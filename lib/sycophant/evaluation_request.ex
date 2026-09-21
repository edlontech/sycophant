defmodule Sycophant.EvaluationRequest do
  @moduledoc """
  Validated input for an evaluation request.

  Carries the model to evaluate against, the arbitrary `state` under
  evaluation (a transcript, a conversation, any JSON-encodable value), and
  the `questions` to ask about it. `new/3` validates structure only: the
  three question shapes (`:boolean`, `:choice`, `:score`) must be well
  formed, but provider limits such as maximum choice count or score level
  count are left to the wire adapter and server.

  This struct is internal to the pipeline: it has no `__type__`
  discriminator and is not registered with `Sycophant.Serializable`.

  ## Question shapes

    * `:boolean` - `%{type: :boolean, instructions: content, criteria: optional %{true: content, false: content}}`
    * `:choice` - `%{type: :choice, instructions: content, criteria: %{(atom | String.t()) => content}}`
    * `:score` - `%{type: :score, instructions: content, criteria: [content]}`

  Where `content` is a string, map, or list.
  """
  use ZoiDefstruct

  alias Sycophant.Error

  defstruct model: Zoi.any(),
            state: Zoi.any(),
            questions: Zoi.any()

  @content Zoi.union([Zoi.string(), Zoi.map(Zoi.any(), Zoi.any()), Zoi.array()])

  @boolean_question Zoi.map(
                      %{
                        type: Zoi.literal(:boolean),
                        instructions: @content,
                        criteria:
                          Zoi.optional(
                            Zoi.map(%{true: @content, false: @content}, unrecognized_keys: :error)
                          )
                      },
                      unrecognized_keys: :error
                    )

  @choice_question Zoi.map(
                     %{
                       type: Zoi.literal(:choice),
                       instructions: @content,
                       criteria: Zoi.map(Zoi.union([Zoi.atom(), Zoi.string()]), @content)
                     },
                     unrecognized_keys: :error
                   )

  @score_question Zoi.map(
                    %{
                      type: Zoi.literal(:score),
                      instructions: @content,
                      criteria: Zoi.array(@content)
                    },
                    unrecognized_keys: :error
                  )

  @question_schema Zoi.discriminated_union(:type, [
                     @boolean_question,
                     @choice_question,
                     @score_question
                   ])

  @doc """
  Builds a validated `EvaluationRequest`.

  Checks, in order: `state` is a binary, map, or list; `questions` is a
  non-empty map whose keys are atoms or strings and whose values match one
  of the three question shapes; no two question keys stringify to the same
  id; and `state`/`questions` together are JSON-encodable.

  Returns `{:error, %Sycophant.Error.Invalid.InvalidParams{}}` on the first
  failed check.
  """
  @spec new(String.t() | LLMDB.Model.t(), String.t() | map() | list(), map()) ::
          {:ok, t()} | {:error, Splode.Error.t()}
  def new(model, state, questions) do
    with :ok <- validate_state(state),
         :ok <- validate_questions(questions),
         :ok <- validate_no_collisions(questions),
         :ok <- validate_json_encodable(state, questions) do
      {:ok, %__MODULE__{model: model, state: state, questions: questions}}
    end
  end

  defp validate_state(state) when is_binary(state) or is_map(state) or is_list(state), do: :ok
  defp validate_state(_state), do: invalid_params("state must be a string, map, or list")

  defp validate_questions(questions) when is_map(questions) and map_size(questions) > 0 do
    Enum.reduce_while(questions, :ok, fn {key, question}, :ok ->
      validate_question(key, question)
    end)
  end

  defp validate_questions(_questions), do: invalid_params("questions must be a non-empty map")

  defp validate_question(key, _question) when not (is_atom(key) or is_binary(key)) do
    {:halt, invalid_params("question key #{inspect(key)} must be an atom or a string")}
  end

  defp validate_question(key, question) do
    case Zoi.parse(@question_schema, question) do
      {:ok, _parsed} ->
        {:cont, :ok}

      {:error, errors} ->
        {:halt, invalid_params("question #{inspect(key)}: #{Zoi.prettify_errors(errors)}")}
    end
  end

  defp validate_no_collisions(questions) do
    ids = Enum.map(Map.keys(questions), &to_string/1)

    if length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      invalid_params("question keys must not collide once stringified")
    end
  end

  defp validate_json_encodable(state, questions) do
    JSON.encode!(%{state: state, questions: questions})
    :ok
  rescue
    error ->
      invalid_params("state and questions must be JSON-encodable: #{Exception.message(error)}")
  end

  defp invalid_params(message) do
    {:error, Error.Invalid.InvalidParams.exception(errors: [message])}
  end
end
