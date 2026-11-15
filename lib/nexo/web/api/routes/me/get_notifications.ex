defmodule Nexo.Web.Api.Routes.Me.GetNotifications do
  use Nexo.Web.Api.Route,
    name: "me.notifications.get",
    method: :get,
    path: "/me/notifications",
    auth: [:student],
    tags: ["notifications"],
    description: "The user's notification preferences and how many devices receive them."

  alias Nexo.Notifications.{Devices, Settings}

  @impl true
  def handle(conn, _params) do
    subject = conn.assigns.current_subject
    {:ok, Map.put(Settings.get(subject), :devices, Devices.count(subject))}
  end
end
