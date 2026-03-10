defmodule Sycophant do
  @moduledoc """
  Unified Elixir client for multiple LLM providers.

  Sycophant abstracts the differences between OpenAI, Anthropic, Google Gemini,
  AWS Bedrock, Azure AI Foundry, and OpenRouter behind a single composable API.
  Provider-specific wire protocols, authentication, and parameter validation
  are handled automatically based on the model identifier.

  ## Text Generation

      messages = [Sycophant.Message.user("What is the capital of France?")]

      {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)
      response.text
      #=> "The capital of France is Paris."

  ## Multi-turn Conversations

  Use `Context` from a previous response to continue the conversation:

      {:ok, response} = Sycophant.generate_text("anthropic:claude-haiku-4-5-20251001", messages)

      ctx = response.context |> Context.add(Message.user("Tell me more"))
      {:ok, follow_up} = Sycophant.generate_text("anthropic:claude-haiku-4-5-20251001", ctx)

  ## Structured Output

  Use `generate_object/4` with a Zoi schema to get validated structured data:

      schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
      messages = [Message.user("Extract: John is 30 years old")]

      {:ok, response} = Sycophant.generate_object("openai:gpt-4o-mini", messages, schema)
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

      Sycophant.generate_text("openai:gpt-4o-mini", messages,
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

      Sycophant.generate_text("openai:gpt-4o-mini", messages,
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

      Sycophant.generate_text("openai:gpt-4o-mini", messages, tools: [weather_tool])

  ## Configuration

  Credentials can be provided per-request, via application config, or through
  environment variables. See `Sycophant.Credentials` for the resolution order.

      # Per-request
      Sycophant.generate_text("openai:gpt-4o-mini", messages,
        credentials: %{api_key: "sk-..."}
      )

      # Application config (config/runtime.exs)
      config :sycophant, :providers,
        openai: [api_key: System.get_env("OPENAI_API_KEY")]
  """

  alias Sycophant.Context
  alias Sycophant.EmbeddingRequest
  alias Sycophant.EmbeddingResponse
  alias Sycophant.Message
  alias Sycophant.Response

  @type model_ref :: String.t() | LLMDB.Model.t()

  @doc """
  Sends a text generation request to the configured LLM provider.

  Model is the first argument, followed by either a list of messages or a
  `Context` struct for multi-turn conversations. When a `Context` is passed,
  tools, streaming, and parameter settings are extracted and merged with
  user-provided opts (user opts take precedence).

  ## Options

    * `:credentials` - Per-request credentials map (optional)
    * `:tools` - List of `Sycophant.Tool` structs (optional)
    * `:stream` - Callback function receiving `StreamChunk` structs (optional)
    * `:max_steps` - Maximum tool execution loop iterations (default: 10)
    * `:temperature`, `:max_tokens`, `:top_p`, etc. - LLM parameters validated
      against the resolved wire protocol's param schema.

  ## Examples

      messages = [Sycophant.Message.user("Hello")]
      {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages)

      {:ok, response} = Sycophant.generate_text("openai:gpt-4o-mini", messages,
        temperature: 0.5,
        max_tokens: 200
      )

      # Continue via Context
      ctx = response.context |> Context.add(Message.user("Thanks!"))
      {:ok, response2} = Sycophant.generate_text("openai:gpt-4o-mini", ctx)
  """
  @spec generate_text(model_ref(), [Message.t()] | Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_text(model, messages_or_context, opts \\ [])

  def generate_text(model, messages, opts) when is_list(messages) do
    Sycophant.Pipeline.call(messages, Keyword.put(opts, :model, model))
  end

  def generate_text(model, %Context{} = context, opts) do
    merged = Keyword.merge(Context.to_opts(context), opts)
    Sycophant.Pipeline.call(context.messages, Keyword.put(merged, :model, model))
  end

  @doc """
  Generates a structured object validated against a Zoi schema.

  Works like `generate_text/3` but instructs the provider to return output
  conforming to `schema`. The parsed and validated result is placed in
  `response.object`.

  ## Options

  Accepts the same options as `generate_text/3`, plus:

    * `:validate` - Whether to validate the output against the schema (default: `true`)

  ## Examples

      schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
      messages = [Sycophant.Message.user("Extract: Alice is 25")]

      {:ok, response} = Sycophant.generate_object("openai:gpt-4o-mini", messages, schema)
      response.object
      #=> %{name: "Alice", age: 25}
  """
  @spec generate_object(model_ref(), [Message.t()] | Context.t(), Zoi.schema(), keyword()) ::
          {:ok, Response.t()} | {:error, Splode.Error.t()}
  def generate_object(model, messages_or_context, schema, opts \\ [])

  def generate_object(model, messages, schema, opts) when is_list(messages) do
    Sycophant.Pipeline.call(
      messages,
      opts |> Keyword.put(:response_schema, schema) |> Keyword.put(:model, model)
    )
  end

  def generate_object(model, %Context{} = context, schema, opts) do
    merged = Keyword.merge(Context.to_opts(context), opts)

    Sycophant.Pipeline.call(
      context.messages,
      merged |> Keyword.put(:response_schema, schema) |> Keyword.put(:model, model)
    )
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
end
