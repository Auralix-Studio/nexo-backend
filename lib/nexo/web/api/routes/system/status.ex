defmodule Nexo.Web.Api.Routes.System.Status do
  use Nexo.Web.Api.Route,
    name: "system.status",
    method: :get,
    path: "/status",
    auth: :public,
    tags: ["system"],
    description: "Lets the app check that the API answers and that its attestation is accepted."

  @impl true
  def handle(_conn, _params) do
    {:ok, %{service: "nexo", status: "ok", time: DateTime.utc_now()}}
  end
end
