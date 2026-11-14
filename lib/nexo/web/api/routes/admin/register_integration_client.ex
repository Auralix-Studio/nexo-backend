defmodule Nexo.Web.Api.Routes.Admin.RegisterIntegrationClient do
  use Nexo.Web.Api.Route,
    name: "admin.integrations.clients.register",
    method: :post,
    path: "/admin/integrations/clients",
    auth: :admin,
    flag: false,
    params: [
      name: [type: :string, required: true, min: 2, max: 60],
      website: [type: :string, max: 200, format: "^https://"]
    ],
    tags: ["admin", "integrations"],
    description: "Registers a third-party app and returns its client_id."

  @impl true
  def handle(_conn, %{name: name} = params) do
    {:ok, client} = Nexo.Integrations.Clients.register(name, website: params[:website])
    {:ok, 201, client}
  end
end
