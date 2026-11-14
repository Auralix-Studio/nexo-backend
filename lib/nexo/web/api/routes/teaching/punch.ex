defmodule Nexo.Web.Api.Routes.Teaching.Punch do
  use Nexo.Web.Api.Route,
    name: "teaching.virtual_classes.punch",
    method: :post,
    path: "/teaching/virtual-classes/:id/punch",
    auth: [:teacher],
    params: [id: [type: :string, required: true, format: "^[A-Za-z0-9_-]{1,40}$"]],
    tags: ["teaching"],
    description: "Checks in or out of one of today's classes; the university decides which."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    Nexo.Teaching.Presence.punch(subject, params.id)
    |> UpstreamReply.reply()
  end
end
