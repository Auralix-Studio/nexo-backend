defmodule Nexo.Web.Api.Routes.Me.GetShared do
  use Nexo.Web.Api.Route,
    name: "me.shared.get",
    method: :get,
    path: "/me/shared",
    auth: [:student],
    tags: ["integrations"],
    description:
      "What the student is sharing, whether the calendar feed is on, and connected apps."

  alias Nexo.Integrations.{Calendar, Connections, SharedData}

  @impl true
  def handle(conn, _params) do
    id = conn.assigns.current_subject.id

    shared =
      case SharedData.get(id) do
        {:ok, data} -> data
        :none -> nil
      end

    {:ok,
     %{
       shared: shared,
       calendar_enabled: Calendar.enabled?(id),
       connections: Connections.list(id)
     }}
  end
end
