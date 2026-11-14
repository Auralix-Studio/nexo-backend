defmodule Nexo.Web.Api.Routes.Admin.SetIntegrationClientStatus do
  use Nexo.Web.Api.Route,
    name: "admin.integrations.clients.status",
    method: :put,
    path: "/admin/integrations/clients/:client_id",
    auth: :admin,
    flag: false,
    params: [
      client_id: [type: :string, format: "^nxc_[A-Za-z0-9_-]{16}$"],
      status: [type: :string, required: true, in: ["active", "suspended"]]
    ],
    tags: ["admin", "integrations"],
    description: "Suspends or reactivates an app; suspending cuts its access at once."

  @impl true
  def handle(_conn, %{client_id: client_id, status: status}) do
    case Nexo.Integrations.Clients.set_status(client_id, status) do
      :ok -> {:ok, %{client_id: client_id, status: status}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
