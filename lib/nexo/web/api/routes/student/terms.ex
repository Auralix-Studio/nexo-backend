defmodule Nexo.Web.Api.Routes.Student.Terms do
  use Nexo.Web.Api.Route,
    name: "student.terms",
    method: :get,
    path: "/terms",
    auth: [:student],
    tags: ["student"],
    description: "The student's terms, newest first, with the active one marked."

  alias Nexo.Academic.Terms

  @impl true
  def handle(conn, _params) do
    case Terms.list(conn.assigns.current_subject) do
      {:ok, terms, sources} -> {:ok, terms, %{sources: sources, fetched_at: DateTime.utc_now()}}
      {:error, :reauth_required} -> {:error, :reauth_required}
    end
  end
end
