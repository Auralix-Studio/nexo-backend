defmodule Nexo.Web.Api.Routes.Student.Terms do
  use Nexo.Web.Api.Route,
    name: "student.terms",
    method: :get,
    path: "/terms",
    auth: [:student],
    tags: ["student"],
    description: "The student's terms, newest first, with the active one marked."

  alias Nexo.Academic.Terms
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject |> Terms.list() |> UpstreamReply.with_sources()
  end
end
