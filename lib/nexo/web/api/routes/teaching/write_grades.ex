defmodule Nexo.Web.Api.Routes.Teaching.WriteGrades do
  use Nexo.Web.Api.Route,
    name: "teaching.grades.write",
    method: :put,
    path: "/teaching/sections/:id/grades",
    auth: [:teacher],
    params: [
      id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"],
      unit_id: [type: :integer, required: true, min: 1],
      type_id: [type: :integer, required: true, min: 1],
      column: [type: :integer, min: 0, max: 20],
      grades: [type: :list, required: true]
    ],
    tags: ["teaching"],
    description:
      "Saves one grade column for several students; insert or update is decided per student."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    if Nexo.Web.Api.Routes.Teaching.Items.valid?(params.grades) do
      Nexo.Teaching.Gradebook.write(subject, params.id, params)
    else
      {:error, :invalid_items}
    end
    |> UpstreamReply.reply()
  end
end
