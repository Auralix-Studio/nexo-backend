defmodule Nexo.Web.Api.Routes.Teaching.VirtualClasses do
  use Nexo.Web.Api.Route,
    name: "teaching.virtual_classes",
    method: :get,
    path: "/teaching/virtual-classes",
    auth: [:teacher],
    tags: ["teaching"],
    description: "Today's classes to check in or out virtually."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    subject = conn.assigns.current_subject

    Nexo.Teaching.Presence.virtual_classes(subject)
    |> UpstreamReply.reply()
  end
end
