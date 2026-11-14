defmodule Nexo.Web.Api.Routes.Me.DeleteShared do
  use Nexo.Web.Api.Route,
    name: "me.shared.delete",
    method: :delete,
    path: "/me/shared",
    auth: [:student],
    tags: ["integrations"],
    description:
      "Stops sharing: deletes the data, the calendar feed and every connected app's access."

  alias Nexo.Integrations.{Calendar, Connections, SharedData}

  @impl true
  def handle(conn, _params) do
    id = conn.assigns.current_subject.id
    meta = %{ip: conn.assigns.client_ip}
    :ok = SharedData.delete(id)
    :ok = Calendar.disable(id, meta)
    :ok = Connections.revoke_all(id)
    {:ok, %{shared: nil}}
  end
end
