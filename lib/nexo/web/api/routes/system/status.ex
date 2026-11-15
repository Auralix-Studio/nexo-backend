defmodule Nexo.Web.Api.Routes.System.Status do
  use Nexo.Web.Api.Route,
    name: "system.status",
    method: :get,
    path: "/status",
    auth: :public,
    # A liveness ping: no attestation (no warnings in the log for each ping)
    # and no feature flag, so it never touches Mongo.
    attest: false,
    flag: false,
    tags: ["system"],
    description:
      "Lets the app check that the API answers. Touches neither Mongo nor the university."

  @impl true
  def handle(_conn, _params) do
    {:ok, %{service: "nexo", status: "ok", time: DateTime.utc_now()}}
  end
end
