defmodule Nexo.Web.Api.Routes.Auth.Logout do
  use Nexo.Web.Api.Route,
    name: "auth.logout",
    method: :post,
    path: "/auth/logout",
    auth: [:student, :teacher, :guardian],
    tags: ["auth"],
    description:
      "Ends every Nexo session of the user and forgets their university sessions, cached data and push devices."

  alias Nexo.Infra.Cache
  alias Nexo.Notifications.Devices
  alias Nexo.Security.Auth
  alias Nexo.Upstream.Sessions

  @impl true
  def handle(conn, _params) do
    %{type: type, id: id} = subject = conn.assigns.current_subject
    Auth.revoke_all(type, id)
    :ok = Sessions.delete(subject)
    :ok = Cache.invalidate_subject(subject)
    :ok = Devices.delete_all(subject)
    {:ok, %{logged_out: true}}
  end
end
