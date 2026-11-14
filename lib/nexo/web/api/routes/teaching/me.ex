defmodule Nexo.Web.Api.Routes.Teaching.Me do
  use Nexo.Web.Api.Route,
    name: "teaching.me",
    method: :get,
    path: "/teaching/me",
    auth: [:teacher],
    tags: ["teaching"],
    description: "The teacher's own profile: code, names, faculty, post and photo."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject
    |> Nexo.Teaching.Account.me()
    |> UpstreamReply.reply()
  end
end
