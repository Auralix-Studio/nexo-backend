defmodule Nexo.Web.Api.Routes.Campus.Wifi do
  use Nexo.Web.Api.Route,
    name: "campus.wifi",
    method: :get,
    path: "/wifi",
    auth: [:student],
    rate_limit: {10, 60},
    tags: ["campus"],
    description: "The student's campus Wi-Fi credential. Never cached (`no-store`)."

  alias Nexo.Campus.Wifi
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject
    |> Wifi.get()
    |> UpstreamReply.reply()
  end
end
