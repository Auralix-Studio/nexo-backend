defmodule Nexo.Web.Api.Routes.Teaching.CorrectAttendance do
  use Nexo.Web.Api.Route,
    name: "teaching.attendance.correct",
    method: :patch,
    path: "/teaching/sections/:id/attendance/:session",
    auth: [:teacher],
    params: [
      id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"],
      session: [
        type: :string,
        required: true,
        format: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"
      ],
      marks: [type: :list, required: true]
    ],
    tags: ["teaching"],
    description: "Corrects marks of a recorded session."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    if Nexo.Web.Api.Routes.Teaching.Items.valid?(params.marks) do
      Nexo.Teaching.Attendance.correct(subject, params.id, params.session, params)
    else
      {:error, :invalid_items}
    end
    |> UpstreamReply.reply()
  end
end
