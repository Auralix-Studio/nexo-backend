defmodule Nexo.Web.Api.Routes.Student.Profile do
  use Nexo.Web.Api.Route,
    name: "student.profile",
    method: :get,
    path: "/profile",
    auth: [:student],
    tags: ["student"],
    description: "The student's profile: career, campus, cycle, credits and cumulative average."

  alias Nexo.Academic.Profile

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    case Profile.get(subject, student) do
      {:ok, profile, sources} -> {:ok, profile, meta(sources)}
      {:error, :reauth_required} -> {:error, :reauth_required}
    end
  end

  defp meta(sources), do: %{sources: sources, fetched_at: DateTime.utc_now()}
end
