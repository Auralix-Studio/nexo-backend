defmodule Nexo.Web.Api.Routes.Teaching.TakeAttendance do
  use Nexo.Web.Api.Route,
    name: "teaching.attendance.take",
    method: :post,
    path: "/teaching/sections/:id/attendance",
    auth: [:teacher],
    params: [
      id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"],
      unit_id: [type: :integer, required: true, min: 1],
      marks: [type: :list, required: true]
    ],
    tags: ["teaching"],
    description: "Records a new session with the university clock."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    if Nexo.Web.Api.Routes.Teaching.Items.valid?(params.marks) do
      Nexo.Teaching.Attendance.take(subject, params.id, params)
    else
      {:error, :invalid_items}
    end
    |> UpstreamReply.reply()
  end
end
