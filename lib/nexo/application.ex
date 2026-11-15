defmodule Nexo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Nexo.Web.Telemetry,
      {DNSCluster, query: Application.get_env(:nexo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nexo.PubSub},
      {Mongo, Nexo.Infra.Db.connection_opts()},
      Nexo.Infra.Cache,
      Nexo.Infra.RateLimiter,
      # Start to serve requests, typically the last entry
      Nexo.Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    children = Enum.reject(children, &is_nil/1)
    opts = [strategy: :one_for_one, name: Nexo.Supervisor]
    result = Supervisor.start_link(children, opts)
    # Fails the boot on colliding API routes instead of serving a wrong table.
    Nexo.Web.Api.Registry.reload!()
    Nexo.Infra.Db.ensure_indexes_async()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Nexo.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
