defmodule Nexo.Web.Api.Routes.Teaching.GradeUnits do
  use Nexo.Web.Api.Route,
    name: "teaching.grade_units",
    method: :get,
    path: "/teaching/sections/:id/grade-units",
    auth: [:teacher],
    params: [id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"]],
    tags: ["teaching"],
    description: "Units of a section, open or closed, with their grade types and scales."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    Nexo.Teaching.Gradebook.grade_units(subject, params.id)
    |> UpstreamReply.reply()
  end
end
