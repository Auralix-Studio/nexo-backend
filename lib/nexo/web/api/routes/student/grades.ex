defmodule Nexo.Web.Api.Routes.Student.Grades do
  use Nexo.Web.Api.Route,
    name: "student.grades",
    method: :get,
    path: "/grades",
    auth: [:student],
    params: [term: [type: :string, format: "^[0-9]{4}-[0-9]$"]],
    tags: ["student"],
    description:
      "A term's courses with current and official grades (default: the active term). " <>
        "One shape for the competencies and legacy models."

  alias Nexo.Academic.Grades
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    conn.assigns.current_subject
    |> Grades.term(params[:term])
    |> UpstreamReply.reply()
  end
end
