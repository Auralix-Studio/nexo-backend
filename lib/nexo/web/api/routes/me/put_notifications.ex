defmodule Nexo.Web.Api.Routes.Me.PutNotifications do
  use Nexo.Web.Api.Route,
    name: "me.notifications.put",
    method: :put,
    path: "/me/notifications",
    auth: [:student],
    rate_limit: {30, 3600},
    params: [grades: [type: :boolean, required: true]],
    tags: ["notifications"],
    description:
      "Turns grade notifications on or off. Turning them off forgets the grades last seen."

  alias Nexo.Notifications.{Devices, Settings}

  @impl true
  def handle(conn, %{grades: grades}) do
    subject = conn.assigns.current_subject
    :ok = Settings.put_grades(subject, grades)
    {:ok, Map.put(Settings.get(subject), :devices, Devices.count(subject))}
  end
end
