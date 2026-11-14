defmodule Nexo.Web.Api.Routes.Student.GradesSummary do
  use Nexo.Web.Api.Route,
    name: "student.grades.summary",
    method: :get,
    path: "/grades/summary",
    auth: [:student],
    tags: ["student"],
    description: "Cumulative average, credits, average per term and the current term so far."

  alias Nexo.Academic.Grades
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    subject
    |> Grades.summary(student)
    |> UpstreamReply.reply()
  end
end
