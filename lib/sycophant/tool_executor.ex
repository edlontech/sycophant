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
    Enum.map(tool_calls, fn tool_call ->
      case Map.fetch(executable_tools, tool_call.name) do
        {:ok, tool} ->
          result = safe_execute(tool.function, tool_call.arguments)
          Message.tool_result(tool_call, result)

        :error ->
          Message.tool_result(
            tool_call,
            "Error: no executable function for tool '#{tool_call.name}'"
          )
      end
    end)
  end

  defp safe_execute(function, arguments) do
    function.(arguments)
  rescue
    e -> Exception.message(e)
  end

  defp build_messages(response, tool_results) do
    Response.messages(response) ++ tool_results
  end
end
