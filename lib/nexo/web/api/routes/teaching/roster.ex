defmodule Nexo.Web.Api.Routes.Teaching.Roster do
  use Nexo.Web.Api.Route,
    name: "teaching.roster",
    method: :get,
    path: "/teaching/sections/:id/students",
    auth: [:teacher],
    params: [id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"]],
    tags: ["teaching"],
    description: "Students of a section with attendance and grades by unit and evaluation type."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    Nexo.Teaching.Gradebook.roster(subject, params.id)
    |> UpstreamReply.reply()
  end
end
