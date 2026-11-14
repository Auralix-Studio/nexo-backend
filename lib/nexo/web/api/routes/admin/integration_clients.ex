defmodule Nexo.Web.Api.Routes.Admin.IntegrationClients do
  use Nexo.Web.Api.Route,
    name: "admin.integrations.clients.list",
    method: :get,
    path: "/admin/integrations/clients",
    auth: :admin,
    flag: false,
    tags: ["admin", "integrations"],
    description: "Third-party apps registered for Connect with Nexo."

  @impl true
  def handle(_conn, _params), do: {:ok, %{clients: Nexo.Integrations.Clients.list()}}
end
