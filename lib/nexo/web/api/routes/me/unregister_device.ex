defmodule Nexo.Web.Api.Routes.Me.UnregisterDevice do
  use Nexo.Web.Api.Route,
    name: "me.devices.unregister",
    method: :delete,
    path: "/me/devices/:token",
    auth: [:student],
    params: [token: [type: :string, required: true, max: 4096, format: "^[A-Za-z0-9_:-]+$"]],
    tags: ["notifications"],
    description: "Forgets a push token of the user (the app calls it before logging out)."

  alias Nexo.Notifications.Devices

  @impl true
  def handle(conn, %{token: token}) do
    :ok = Devices.unregister(conn.assigns.current_subject, token)
    {:ok, %{registered: false}}
  end
end
