defmodule Nexo.Web.Api.Routes.Student.Curriculum do
  use Nexo.Web.Api.Route,
    name: "student.curriculum",
    method: :get,
    path: "/curriculum",
    auth: [:student],
    tags: ["student"],
    description: "The study plan's courses by cycle with status, grade and credits."

  alias Nexo.Academic.Grades
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    subject
    |> Grades.curriculum(student)
    |> UpstreamReply.reply()
  end
end
