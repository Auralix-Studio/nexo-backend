defmodule Nexo.Web.Api.Routes.Teaching.Punches do
  use Nexo.Web.Api.Route,
    name: "teaching.punches",
    method: :get,
    path: "/teaching/punches",
    auth: [:teacher],
    params: [
      from: [type: :string, format: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"],
      to: [type: :string, format: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"]
    ],
    tags: ["teaching"],
    description: "The teacher's punch history (default: last 30 days)."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    subject = conn.assigns.current_subject

    {from, to} = Nexo.Web.Api.Routes.Teaching.Items.range(params, 30)

    Nexo.Teaching.Presence.punches(subject, from, to)
    |> UpstreamReply.reply()
  end
end
