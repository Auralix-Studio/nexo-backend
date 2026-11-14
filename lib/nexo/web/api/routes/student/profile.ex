defmodule Nexo.Web.Api.Routes.Student.Profile do
  use Nexo.Web.Api.Route,
    name: "student.profile",
    method: :get,
    path: "/profile",
    auth: [:student],
    tags: ["student"],
    description: "The student's profile: career, campus, cycle, credits and cumulative average."

  alias Nexo.Academic.Profile
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject
    subject |> Profile.get(student) |> UpstreamReply.with_sources()
  end
end
