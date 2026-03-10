defmodule Sycophant do
  @moduledoc """
  Unified Elixir client for multiple LLM providers.

  Sycophant abstracts the differences between OpenAI, Anthropic, Google Gemini,
  AWS Bedrock, Azure AI Foundry, and OpenRouter behind a single composable API.
  Provider-specific wire protocols, authentication, and parameter validation
  are handled automatically based on the model identifier.

  ## Text Generation

      messages = [Sycophant.Message.user("What is the capital of France?")]

      {:ok, response} = Sycophant.generate_text(messages, model: "openai:gpt-4o-mini")
      response.text
      #=> "The capital of France is Paris."

  ## Multi-turn Conversations

  Pass a previous `Response` back with a new `Message` to continue the conversation.
  Model, tools, and parameters are carried over automatically:

      {:ok, response} = Sycophant.generate_text(messages, model: "anthropic:claude-haiku-4-5-20251001")

      {:ok, follow_up} = Sycophant.generate_text(response, Message.user("Tell me more"))

  ## Structured Output

  Use `generate_object/3` with a Zoi schema to get validated structured data:

      schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
      messages = [Message.user("Extract: John is 30 years old")]

      {:ok, response} = Sycophant.generate_object(messages, schema, model: "openai:gpt-4o-mini")
      response.object
      #=> %{name: "John", age: 30}

  ## Parameters

  LLM parameters like `temperature` and `max_tokens` are passed as flat keyword
  options. Each wire protocol declares its own param schema composed from shared
  definitions plus wire-specific extras. Only parameters supported by the resolved
  wire protocol are sent to the provider; unsupported params are dropped
  with a warning log. LLMDB model constraints (e.g., temperature unsupported)
  are applied automatically.

  Common shared params: `:temperature`, `:max_tokens`, `:top_p`, `:top_k`,
  `:stop`, `:reasoning`, `:reasoning_summary`, `:service_tier`, `:tool_choice`,
  `:parallel_tool_calls`.

  Wire-specific params are passed as flat keywords alongside shared ones. For
  example, OpenAI completions accept `:logprobs`, `:seed`, and `:top_logprobs`:

      Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        temperature: 0.7,
        max_tokens: 500,
        logprobs: true,
        seed: 42
      )

  ## Embeddings

      request = %Sycophant.EmbeddingRequest{
        inputs: ["Hello world"],
        model: "amazon_bedrock:cohere.embed-english-v3"
      }
      {:ok, response} = Sycophant.embed(request)
      response.embeddings
      #=> %{float: [[0.123, -0.456, ...]]}

  ## Streaming

  Pass a callback function via the `:stream` option to receive chunks as they arrive:

      Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        stream: fn chunk -> IO.write(chunk.data) end
      )

  ## Tool Use

  Define tools with auto-execution functions or handle tool calls manually:

      weather_tool = %Sycophant.Tool{
        name: "get_weather",
        description: "Gets current weather for a city",
        parameters: Zoi.object(%{city: Zoi.string()}),
        function: fn %{"city" => city} -> "72F sunny in \#{city}" end
      }

      Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        tools: [weather_tool]
      )

  ## Configuration

  Credentials can be provided per-request, via application config, or through
  environment variables. See `Sycophant.Credentials` for the resolution order.

      # Per-request
      Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        credentials: %{api_key: "sk-..."}
      )

      # Application config (config/runtime.exs)
      config :sycophant, :providers,
        openai: [api_key: System.get_env("OPENAI_API_KEY")]
  """

  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Message
  alias Sycophant.Response

  @doc """
  Sends a text generation request to the configured LLM provider.

  Accepts either a list of `Message` structs with keyword options, or a previous
  `Response` together with a follow-up `Message` to continue the conversation.
  When a `Response` is passed, the model, tools, streaming, and parameter settings
  are automatically carried over from its context.

  ## Options

    * `:model` - Model identifier as `"provider:model_id"` (required for new conversations)
    * `:credentials` - Per-request credentials map (optional)
    * `:tools` - List of `Sycophant.Tool` structs (optional)
    * `:stream` - Callback function receiving `StreamChunk` structs (optional)
    * `:max_steps` - Maximum tool execution loop iterations (default: 10)
    * `:temperature`, `:max_tokens`, `:top_p`, etc. - LLM parameters validated
      against the resolved wire protocol's param schema. Unsupported params for
      the target provider are dropped with a debug log.

  Wire-specific params can also be passed as flat keywords (e.g., `logprobs: true`
  for OpenAI, `cache_key: "key"` for OpenAI Responses). See the wire protocol
  modules for the full list of supported params per provider.

  ## Examples

      messages = [Sycophant.Message.user("Hello")]
      {:ok, response} = Sycophant.generate_text(messages, model: "openai:gpt-4o-mini")

      # With params
      {:ok, response} = Sycophant.generate_text(messages,
        model: "openai:gpt-4o-mini",
        temperature: 0.5,
        max_tokens: 200
      )

      # Continue the conversation
      {:ok, response2} = Sycophant.generate_text(response, Sycophant.Message.user("Thanks!"))
  """
  @spec generate_text([Message.t()] | Response.t(), keyword() | Message.t()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_text(messages_or_response, opts_or_message \\ [])

  def generate_text(messages, opts) when is_list(messages) do
    Sycophant.Pipeline.call(messages, opts)
  end

  def generate_text(%Response{context: context}, %Message{} = message) do
    messages = context.messages ++ [message]

    opts =
      [
        model: context.model,
        tools: context.tools,
        stream: context.stream
      ] ++ params_to_opts(context.params)

    Sycophant.Pipeline.call(messages, opts)
  end

  @doc """
  Generates a structured object validated against a Zoi schema.

  Works like `generate_text/2` but instructs the provider to return output
  conforming to `schema`. The parsed and validated result is placed in
  `response.object`. When continuing from a previous `Response`, the schema
  stored in its context is reused automatically.

  ## Options

  Accepts the same options as `generate_text/2`, plus:

    * `:validate` - Whether to validate the output against the schema (default: `true`)

  ## Examples

      schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
      messages = [Sycophant.Message.user("Extract: Alice is 25")]

      {:ok, response} = Sycophant.generate_object(messages, schema, model: "openai:gpt-4o-mini")
      response.object
      #=> %{name: "Alice", age: 25}
  """
  @spec generate_object([Message.t()] | Response.t(), Zoi.schema() | Message.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_object(messages_or_response, schema_or_message, opts \\ [])

  def generate_object(messages, schema, opts) when is_list(messages) do
    Sycophant.Pipeline.call(messages, Keyword.put(opts, :response_schema, schema))
  end

  def generate_object(%Response{context: context}, %Message{} = message, _opts) do
    messages = context.messages ++ [message]

    opts =
      [
        model: context.model,
        tools: context.tools,
        stream: context.stream,
        response_schema: context.response_schema
      ] ++ params_to_opts(context.params)

    Sycophant.Pipeline.call(messages, opts)
  end

  @doc """
  Generates embeddings for the given inputs.

  Accepts an `EmbeddingRequest` struct containing inputs (text, images,
  or mixed), model specification, and optional parameters.

  ## Examples

      request = %Sycophant.EmbeddingRequest{
        inputs: ["Hello world", "Goodbye world"],
        model: "amazon_bedrock:cohere.embed-english-v3"
      }
      {:ok, response} = Sycophant.embed(request)
      length(response.embeddings.float)
      #=> 2
  """
  @spec embed(EmbeddingRequest.t(), keyword()) ::
          {:ok, EmbeddingResponse.t()} | {:error, Splode.Error.t()}
  def embed(%EmbeddingRequest{} = request, opts \\ []) do
    Sycophant.EmbeddingPipeline.call(request, opts)
  end

  defp params_to_opts(params) when is_map(params) do
    params
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.new()
  end

  defp params_to_opts(nil), do: []
end
