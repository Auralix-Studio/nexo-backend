defmodule Nexo.Web.Api.Routes.Teaching.ServerTime do
  use Nexo.Web.Api.Route,
    name: "teaching.server_time",
    method: :get,
    path: "/teaching/server-time",
    auth: [:teacher],
    tags: ["teaching"],
    description: "SIGMA's clock in Lima time (the backend's own clock if SIGMA is down)."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject
    |> Nexo.Teaching.Account.server_time()
    |> UpstreamReply.reply()
  end
end
