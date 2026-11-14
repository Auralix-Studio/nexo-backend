defmodule Nexo.Web.Api.Routes.Student.Schedule do
  use Nexo.Web.Api.Route,
    name: "student.schedule",
    method: :get,
    path: "/schedule",
    auth: [:student],
    params: [term: [type: :string, format: "^[0-9]{4}-[0-9]$"]],
    tags: ["student"],
    description:
      "Weekly schedule of a term (default: the active one), Language Center classes included."

  alias Nexo.Academic.Schedule
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    %{record: student} = subject = conn.assigns.current_subject
    subject |> Schedule.get(student, params[:term]) |> UpstreamReply.with_sources()
  end
end
