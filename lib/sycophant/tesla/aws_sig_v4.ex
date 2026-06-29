if Code.ensure_loaded?(ExAws.Auth) do
  defmodule Sycophant.Tesla.AwsSigV4 do
    @moduledoc """
    Tesla middleware that signs requests with AWS Signature Version 4.

    Vendored from `tesla_aws_sigv4`. Wraps the SigV4 signing process
    implemented in `ex_aws` so manually constructed requests to AWS APIs
    (e.g. Bedrock) can be signed. It does not use any of the service
    libraries in `ex_aws`; it only signs the request currently in flight.

    `ex_aws` is an optional dependency, so this module is only compiled when
    `ex_aws` is available. Consumers that target AWS Bedrock must add
    `{:ex_aws, "~> 2.6"}` to their own deps.

    ## Options

      * `:service` - Required canonical name of the AWS service used in the
        signing process.
      * `:config` - Optional overrides for `ex_aws` config. Only config
        related to the signing process is supported.
    """

    @behaviour Tesla.Middleware

    @impl true
    def call(env, next, opts) do
      service = Keyword.fetch!(opts, :service)

      config =
        ExAws.Config.Defaults.defaults(service)
        |> Map.merge(Keyword.get(opts, :config, %{}))
        |> ExAws.Config.retrieve_runtime_config()

      env
      |> sign_request(service, config)
      |> Tesla.run(next)
    end

    defp sign_request(env, service, config) do
      {:ok, headers} =
        ExAws.Auth.headers(
          env.method,
          env.url,
          service,
          config,
          env.headers,
          env.body || ""
        )

      %{env | headers: headers}
    end
  end
end
