defmodule Sycophant.Context do
  @moduledoc """
  Public conversation handle for multi-turn LLM interactions.

  Context is a builder for conversation state. It holds message history,
  tools, streaming callbacks, and provider params. Model and response schema
  are per-call concerns and live outside the context.

  ## Building a conversation

      ctx = Context.new()
            |> Context.add(Message.system("You are helpful."))
            |> Context.add(Message.user("Hello!"))

  ## Passing options

      opts = Context.to_opts(ctx)
  """
  use TypedStruct

  alias Sycophant.Serializable.Decoder

  typedstruct do
    field :messages, [Sycophant.Message.t()], default: []
    field :params, map(), default: %{}
    field :tools, [Sycophant.Tool.t()], default: []
    field :stream, (term() -> term())
  end

  @doc "Creates an empty context."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Creates a context from a message list or keyword opts."
  @spec new([Sycophant.Message.t()] | keyword()) :: t()
  def new(messages) when is_list(messages) and not is_tuple(hd(messages)) do
    %__MODULE__{messages: messages}
  end

  def new(opts) when is_list(opts), do: new([], opts)

  @doc "Creates a context from messages and keyword opts."
  @spec new([Sycophant.Message.t()], keyword()) :: t()
  def new(messages, opts) when is_list(messages) and is_list(opts) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {stream, opts} = Keyword.pop(opts, :stream)
    params = opts |> Keyword.drop([:credentials, :max_steps]) |> Map.new()

    %__MODULE__{
      messages: messages,
      tools: tools,
      stream: stream,
      params: params
    }
  end

  @doc "Appends one or more messages to the context."
  @spec add(t(), Sycophant.Message.t() | [Sycophant.Message.t()]) :: t()
  def add(%__MODULE__{} = ctx, messages) when is_list(messages) do
    %{ctx | messages: ctx.messages ++ messages}
  end

  def add(%__MODULE__{} = ctx, %Sycophant.Message{} = message) do
    %{ctx | messages: ctx.messages ++ [message]}
  end

  @doc "Converts context fields into flat keyword opts for pipeline consumption."
  @spec to_opts(t()) :: keyword()
  def to_opts(%__MODULE__{} = ctx) do
    base =
      []
      |> maybe_add(:tools, ctx.tools)
      |> maybe_add(:stream, ctx.stream)

    params_opts =
      ctx.params
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.new()

    Keyword.merge(base, params_opts)
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, []), do: opts
  defp maybe_add(opts, _key, map) when is_map(map) and map_size(map) == 0, do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Deserializes a context from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    opts = Map.get(data, :opts, [])

    %__MODULE__{
      messages: Enum.map(data["messages"], &Decoder.from_map/1),
      params: decode_params(data["params"]),
      tools: decode_tools(data["tools"], opts),
      stream: nil
    }
  end

  defp decode_params(nil), do: %{}

  defp decode_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  rescue
    ArgumentError -> params
  end

  defp decode_tools(nil, _opts), do: []

  defp decode_tools(tools, opts),
    do: Enum.map(tools, &Decoder.from_map(Map.put(&1, :opts, opts), opts))
end

defimpl Sycophant.Serializable, for: Sycophant.Context do
  import Sycophant.Serializable.Helpers

  def to_map(ctx) do
    compact(%{
      "__type__" => "Context",
      "messages" => Enum.map(ctx.messages, &Sycophant.Serializable.to_map/1),
      "params" => encode_params(ctx.params),
      "tools" => encode_tools(ctx.tools)
    })
  end

  defp encode_params(params) when map_size(params) == 0, do: nil

  defp encode_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp encode_tools([]), do: nil
  defp encode_tools(tools), do: Enum.map(tools, &Sycophant.Serializable.to_map/1)
end

defimpl Inspect, for: Sycophant.Context do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(ctx, opts) do
    fields =
      Enum.reject(
        [
          messages: length(ctx.messages),
          tools: length(ctx.tools),
          stream: InspectHelpers.fn_label(ctx.stream)
        ],
        fn {_, v} -> is_nil(v) or v == 0 end
      )

    concat(["#Sycophant.Context<", to_doc(Map.new(fields), opts), ">"])
  end
end
