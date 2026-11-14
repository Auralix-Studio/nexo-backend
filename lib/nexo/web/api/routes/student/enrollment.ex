defmodule Nexo.Web.Api.Routes.Student.Enrollment do
  use Nexo.Web.Api.Route,
    name: "student.enrollment",
    method: :get,
    path: "/enrollment",
    auth: [:student],
    params: [term: [type: :string, format: "^[0-9]{4}-[0-9]$"]],
    tags: ["student"],
    description: "Data for the enrollment certificate of a term (default: the active one)."

  alias Nexo.Academic.Enrollment
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    %{record: student} = subject = conn.assigns.current_subject

    subject
    |> Enrollment.get(student, params[:term])
    |> UpstreamReply.reply()
  end
end
