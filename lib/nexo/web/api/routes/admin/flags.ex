defmodule Nexo.Web.Api.Routes.Admin.Flags do
  use Nexo.Web.Api.Route,
    name: "admin.flags.list",
    method: :get,
    path: "/admin/flags",
    auth: :admin,
    flag: false,
    tags: ["admin"],
    description: "Feature flags that were switched explicitly. Unlisted flags are on."

  @impl true
  def handle(_conn, _params), do: {:ok, %{flags: Nexo.Infra.Flags.list()}}
end
