defmodule Sycophant.OpenAIAccessTokenTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Sycophant.Message
  alias Sycophant.Transport

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    stub(LLMDB, :model, fn spec ->
      id = String.replace_prefix(spec, "openai:", "")

      {:ok,
       %LLMDB.Model{
         id: id,
         provider: :openai,
         capabilities: %{reasoning: %{enabled: id == "gpt-5-nano"}},
         extra: %{wire: %{protocol: "openai_responses"}}
       }}
    end)

    stub(LLMDB, :provider, fn :openai ->
      {:ok, %LLMDB.Provider{id: :openai, base_url: "https://api.openai.com/v1"}}
    end)

    :ok
  end

  test "API keys retain synchronous transport and caller parameters" do
    reject(Transport, :stream, 3)

    expect(Transport, :call, fn payload, opts ->
      assert payload["temperature"] == 0.2
      refute Map.has_key?(payload, "store")
      refute Map.has_key?(payload, "stream")

      assert opts[:auth_middlewares] == [
               {Tesla.Middleware.Headers, [{"authorization", "Bearer k"}]}
             ]

      {:ok, %{"id" => "resp-1", "output" => [], "usage" => %{}}}
    end)

    assert {:ok, _} =
             Sycophant.generate_text("openai:gpt-4o-mini", [Message.user("Hi")],
               credentials: %{api_key: "k"},
               temperature: 0.2
             )
  end

  test "application configuration resolves and redacts access tokens" do
    previous = Application.get_env(:sycophant, :providers)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:sycophant, :providers),
        else: Application.put_env(:sycophant, :providers, previous)
    end)

    Application.put_env(:sycophant, :providers, openai: [access_token: "secret-token"])

    assert {:ok, config} = Sycophant.Config.provider(:openai)
    assert Map.fetch!(config, :access_token) == "secret-token"
    refute inspect(config) =~ "secret-token"
    assert {:ok, %{access_token: "secret-token"}} = Sycophant.Credentials.resolve(:openai, nil)
  end

  test "access tokens enforce subscription payloads and hidden streaming" do
    assert {:ok, Sycophant.Auth.OpenAI} = Sycophant.Registry.fetch_auth(:openai)
    reject(Transport, :call, 2)

    for model <- ["gpt-5-nano", "gpt-4o-mini"] do
      expect(Transport, :stream, fn payload, opts, on_event ->
        assert payload["store"] == false
        assert payload["stream"] == true
        assert payload["instructions"] == "Be helpful"
        assert payload["input"] == [%{"role" => "user", "content" => "Hi"}]

        for key <- ["temperature", "max_output_tokens", "top_p", "previous_response_id"] do
          refute Map.has_key?(payload, key)
        end

        if model == "gpt-5-nano" do
          assert payload["include"] == ["reasoning.encrypted_content"]
        else
          refute Map.has_key?(payload, "include")
        end

        assert opts[:auth_middlewares] == [
                 {Tesla.Middleware.Headers, [{"authorization", "Bearer t"}]}
               ]

        {:ok,
         on_event.([
           %{
             event: "response.completed",
             data:
               JSON.encode!(%{"response" => %{"id" => "resp-1", "output" => [], "usage" => %{}}})
           }
         ])}
      end)

      assert {:ok, response} =
               Sycophant.generate_text(
                 "openai:#{model}",
                 [Message.system("Be helpful"), Message.user("Hi")],
                 credentials: %{access_token: "t"},
                 temperature: 0.2,
                 store: true,
                 max_tokens: 100,
                 top_p: 0.9,
                 previous_response_id: "resp-old"
               )

      assert response.context.stream == nil
    end
  end
end
