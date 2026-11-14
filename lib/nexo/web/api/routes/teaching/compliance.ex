defmodule Nexo.Web.Api.Routes.Teaching.Compliance do
  use Nexo.Web.Api.Route,
    name: "teaching.compliance",
    method: :get,
    path: "/teaching/compliance",
    auth: [:teacher],
    params: [
      from: [type: :string, format: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"],
      to: [type: :string, format: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"]
    ],
    tags: ["teaching"],
    description:
      "Scheduled classes with their check-in and check-out status (default: last 14 days)."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    {from, to} = Nexo.Web.Api.Routes.Teaching.Items.range(params, 14)

    conn.assigns.current_subject
    |> Nexo.Teaching.Presence.compliance(from, to)
    |> UpstreamReply.reply()
  end
end
