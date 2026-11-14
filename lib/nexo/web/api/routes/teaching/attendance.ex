defmodule Nexo.Web.Api.Routes.Teaching.Attendance do
  use Nexo.Web.Api.Route,
    name: "teaching.attendance",
    method: :get,
    path: "/teaching/sections/:id/attendance",
    auth: [:teacher],
    params: [id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"]],
    tags: ["teaching"],
    description: "Attendance sheet of a section: units, sessions, students and their marks."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    Nexo.Teaching.Attendance.sheet(subject, params.id)
    |> UpstreamReply.reply()
  end
end
