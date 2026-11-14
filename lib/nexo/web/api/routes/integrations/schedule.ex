defmodule Nexo.Web.Api.Routes.Integrations.Schedule do
  use Nexo.Web.Api.Route,
    name: "integrations.schedule",
    method: :get,
    path: "/integrations/schedule",
    auth: :integration,
    scopes: ["schedule"],
    tags: ["integrations"],
    description:
      "The weekly schedule the student shared: term and classes (Lima time, ISO weekdays)."

  @impl true
  def handle(conn, _params) do
    case Nexo.Integrations.SharedData.get(conn.assigns.current_subject.student_id) do
      {:ok, data} -> {:ok, %{schedule: data["schedule"], updated_at: data["updated_at"]}}
      :none -> {:error, :not_found}
    end
  end
end
