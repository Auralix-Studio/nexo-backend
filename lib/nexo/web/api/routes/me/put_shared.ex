defmodule Nexo.Web.Api.Routes.Me.PutShared do
  use Nexo.Web.Api.Route,
    name: "me.shared.put",
    method: :put,
    path: "/me/shared",
    auth: [:student],
    rate_limit: {30, 3600},
    params: [profile: [type: :map], schedule: [type: :map]],
    tags: ["integrations"],
    description: "Stores the profile and schedule the student chose to share with integrations."

  alias Nexo.Integrations.SharedData

  @impl true
  def handle(conn, params) do
    payload = %{"profile" => params[:profile], "schedule" => params[:schedule]}

    case SharedData.put(conn.assigns.current_subject.id, payload) do
      {:ok, data} -> {:ok, data}
      {:error, details} -> {:error, 422, :invalid_params, inspect_details(details)}
    end
  end

  defp inspect_details(details),
    do: Enum.map_join(details, "; ", fn %{field: f, reason: r} -> "#{f} #{r}" end)
end
