defmodule Nexo.Web.Api.Routes.Admin.SetFlag do
  use Nexo.Web.Api.Route,
    name: "admin.flags.set",
    method: :put,
    path: "/admin/flags/:name",
    auth: :admin,
    flag: false,
    rate_limit: {30, 60},
    params: [
      name: [type: :string, required: true, format: "^[a-z0-9_.-]{1,64}$"],
      enabled: [type: :boolean, required: true]
    ],
    tags: ["admin"],
    description: "Switches a route on or off at runtime. Only routes that use flags qualify."

  alias Nexo.Web.Api.Registry

  @impl true
  def handle(conn, %{name: name, enabled: enabled}) do
    known = for %{flag: flag} <- Registry.routes(), flag, do: flag

    if name in known do
      :ok = Nexo.Infra.Flags.set(name, enabled, "admin", %{ip: conn.assigns.client_ip})
      {:ok, %{name: name, enabled: enabled}}
    else
      {:error, 404, :unknown_flag, "No route uses a flag with that name."}
    end
  end
end
