defmodule Nexo.Web.Api.Routes.Me.RevokeConnection do
  use Nexo.Web.Api.Route,
    name: "me.connections.revoke",
    method: :delete,
    path: "/me/connections/:id",
    auth: [:student],
    params: [id: [type: :string, format: "^[a-f0-9]{24}$"]],
    tags: ["integrations"],
    description: "Removes a connected app's access at once."

  @impl true
  def handle(conn, %{id: id}) do
    case Nexo.Integrations.Connections.revoke(conn.assigns.current_subject.id, id, %{
           ip: conn.assigns.client_ip
         }) do
      :ok -> {:ok, %{revoked: id}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
