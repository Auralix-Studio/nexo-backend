defmodule Nexo.Web.Api.Routes.Integrations.Profile do
  use Nexo.Web.Api.Route,
    name: "integrations.profile",
    method: :get,
    path: "/integrations/profile",
    auth: :integration,
    scopes: ["profile"],
    tags: ["integrations"],
    description: "The profile the student shared: code, name, career, faculty and cycle."

  @impl true
  def handle(conn, _params) do
    case Nexo.Integrations.SharedData.get(conn.assigns.current_subject.student_id) do
      {:ok, data} -> {:ok, %{profile: data["profile"] || %{}, updated_at: data["updated_at"]}}
      :none -> {:error, :not_found}
    end
  end
end
