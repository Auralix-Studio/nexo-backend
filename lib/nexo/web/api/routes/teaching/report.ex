defmodule Nexo.Web.Api.Routes.Teaching.Report do
  use Nexo.Web.Api.Route,
    name: "teaching.report",
    method: :get,
    path: "/teaching/sections/:id/report",
    auth: [:teacher],
    rate_limit: {20, 60},
    params: [
      id: [type: :string, required: true, format: "^sec_[0-9a-f]{16}$"],
      format: [type: :string, format: "^(pdf|xlsx)$"]
    ],
    tags: ["teaching"],
    description: "The section's auxiliary register as a file (PDF by default, or XLSX), not JSON."

  import Plug.Conn

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, params) do
    case Nexo.Teaching.Account.report(conn.assigns.current_subject, params.id, params[:format]) do
      {:ok, file} ->
        conn
        |> put_resp_header("content-type", file.content_type)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{file.filename}"))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, file.body)

      error ->
        UpstreamReply.reply(error)
    end
  end
end
