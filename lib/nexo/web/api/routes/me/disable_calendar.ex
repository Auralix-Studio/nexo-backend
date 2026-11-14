defmodule Nexo.Web.Api.Routes.Me.DisableCalendar do
  use Nexo.Web.Api.Route,
    name: "me.calendar.disable",
    method: :delete,
    path: "/me/calendar",
    auth: [:student],
    tags: ["integrations"],
    description: "Turns the calendar link off; subscribed calendars stop updating."

  @impl true
  def handle(conn, _params) do
    :ok =
      Nexo.Integrations.Calendar.disable(conn.assigns.current_subject.id, %{
        ip: conn.assigns.client_ip
      })

    {:ok, %{calendar_enabled: false}}
  end
end
