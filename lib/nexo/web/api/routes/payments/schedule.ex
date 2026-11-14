defmodule Nexo.Web.Api.Routes.Payments.Schedule do
  use Nexo.Web.Api.Route,
    name: "payments.schedule",
    method: :get,
    path: "/payments/schedule",
    auth: [:student],
    tags: ["payments"],
    description: "The current term's installment plan."

  alias Nexo.Billing.Payments
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    conn.assigns.current_subject
    |> Payments.schedule()
    |> UpstreamReply.reply()
  end
end
