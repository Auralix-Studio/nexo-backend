defmodule Nexo.Web.Api.Routes.Campus.Publications do
  use Nexo.Web.Api.Route,
    name: "campus.publications",
    method: :get,
    path: "/publications",
    auth: [:student],
    tags: ["campus"],
    description: "University announcements for the home screen."

  alias Nexo.Campus.Publications
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject
    |> Publications.list()
    |> UpstreamReply.reply()
  end
end
