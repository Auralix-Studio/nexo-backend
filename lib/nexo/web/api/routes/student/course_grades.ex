defmodule Nexo.Web.Api.Routes.Student.CourseGrades do
  use Nexo.Web.Api.Route,
    name: "student.grades.course",
    method: :get,
    path: "/grades/:term/courses/:id",
    auth: [:student],
    params: [
      term: [type: :string, required: true, format: "^[0-9]{4}-[0-9]$"],
      id: [type: :string, required: true, format: "^[A-Za-z0-9_-]{1,20}$"]
    ],
    tags: ["student"],
    description: "One course of a term: units, evidences, final grade and what is needed to pass."

  alias Nexo.Academic.Grades
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, %{term: term, id: id}) do
    conn.assigns.current_subject
    |> Grades.course(term, id)
    |> UpstreamReply.reply()
  end
end
