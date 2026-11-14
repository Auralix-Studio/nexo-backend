defmodule Nexo.Web.Api.Routes.Student.Languages do
  use Nexo.Web.Api.Route,
    name: "student.languages",
    method: :get,
    path: "/languages",
    auth: [:student],
    tags: ["student"],
    description: "Language Center courses with their schedule and grades."

  alias Nexo.Academic.Languages
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    case Languages.list(subject, student) do
      {:ok, courses, status} -> {:ok, %{courses: courses}, %{languages: status}}
      error -> error
    end
    |> UpstreamReply.with_sources()
  end
end
