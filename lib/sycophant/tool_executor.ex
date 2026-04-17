defmodule Sycophant.ToolExecutor do
  @moduledoc """
  Automatic tool execution loop.

  When a response contains tool calls and the corresponding `Tool` structs
  have a `:function` set, this module executes them, builds `tool_result`
  messages, and re-submits to the LLM until it produces a final text
  response or `:max_steps` is reached (default: 10).

  Tools without a `:function` are skipped -- their tool calls appear in
  `response.tool_calls` for manual handling by the caller.
  """

  alias Sycophant.Message
  alias Sycophant.Response
  alias Sycophant.Tool

  @default_max_steps 10

  @doc "Runs the tool auto-execution loop until no more tool calls remain or max_steps is reached."
  @spec run(Response.t(), [Tool.t()], keyword(), (list() ->
                                                    {:ok, Response.t()} | {:error, term()})) ::
          {:ok, Response.t()} | {:error, term()}
  def run(response, tools, opts, call_fn) do
    max_steps = opts[:max_steps] || @default_max_steps
    executable_tools = build_executable_map(tools)

    if map_size(executable_tools) == 0 do
      {:ok, response}
    else
      loop(response, executable_tools, call_fn, max_steps, 0)
    end
  end

  defp loop(%Response{tool_calls: []} = response, _tools, _call_fn, _max_steps, _step) do
    {:ok, response}
  end

  defp loop(response, _executable_tools, _call_fn, max_steps, step)
       when step >= max_steps do
    {:ok, response}
  end

  defp loop(response, executable_tools, call_fn, max_steps, step) do
    results = execute_tools(response.tool_calls, executable_tools)
    messages = build_messages(response, results)

    case call_fn.(messages) do
      {:ok, new_response} ->
        loop(new_response, executable_tools, call_fn, max_steps, step + 1)

      {:error, _} = error ->
        error
    end
  end

  defp build_executable_map(tools) do
    tools
    |> Enum.filter(& &1.function)
    |> Map.new(&{&1.name, &1})
  end

  defp execute_tools(tool_calls, executable_tools) do
    Enum.map(tool_calls, &execute_single_tool(&1, executable_tools))
  end

  defp execute_single_tool(tool_call, executable_tools) do
    case Map.fetch(executable_tools, tool_call.name) do
      {:ok, tool} ->
        execute_with_validation(tool_call, tool)

      :error ->
        Message.tool_result(
          tool_call,
          "Error: no executable function for tool '#{tool_call.name}'"
        )
    end
  end

  defp execute_with_validation(tool_call, tool) do
    case validate_and_coerce(tool, tool_call.arguments) do
      {:ok, coerced_args} ->
        result = safe_execute(tool.function, coerced_args)
        Message.tool_result(tool_call, normalize_result(result))

      {:error, error} ->
        Message.tool_result(tool_call, "Validation error: #{Exception.message(error)}")
    end
  end

  defp validate_and_coerce(%{resolved_schema: nil}, arguments), do: {:ok, arguments}

  defp validate_and_coerce(%{resolved_schema: schema}, arguments) do
    Sycophant.Schema.Validator.validate(schema, arguments)
  end

  defp safe_execute(function, arguments) do
    function.(arguments)
  rescue
    e -> Exception.message(e)
  end

  # Coerce arbitrary tool return values into a string that can safely flow
  # through wire-protocol serialization. Without this, a map or list would
  # reach `to_string/1` in the wire encoder and crash.
  defp normalize_result(result) when is_binary(result), do: result
  defp normalize_result({:ok, value}), do: normalize_result(value)
  defp normalize_result({:error, reason}) when is_binary(reason), do: "Error: #{reason}"
  defp normalize_result({:error, reason}), do: "Error: #{inspect(reason)}"
  defp normalize_result(nil), do: ""
  defp normalize_result(result) when is_atom(result) or is_number(result), do: to_string(result)

  defp normalize_result(result) when is_map(result) or is_list(result) do
    JSON.encode!(result)
  rescue
    _ -> inspect(result)
  end

  defp normalize_result(result), do: inspect(result)

  defp build_messages(response, tool_results) do
    Response.messages(response) ++ tool_results
  end
end
