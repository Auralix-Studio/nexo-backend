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

  @impl true
  def handle(conn, params) do
    %{record: student} = subject = conn.assigns.current_subject

    case Schedule.get(subject, student, params[:term]) do
      {:ok, schedule, sources} ->
        {:ok, schedule, %{sources: sources, fetched_at: DateTime.utc_now()}}

      {:error, :unknown_term} ->
        {:error, 404, :unknown_term, "The student has no such term."}

      {:error, :reauth_required} ->
        {:error, :reauth_required}
    end
  end
end
