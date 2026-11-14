defmodule Nexo.Web.Api.Routes.Payments.History do
  use Nexo.Web.Api.Route,
    name: "payments.history",
    method: :get,
    path: "/payments/history",
    auth: [:student],
    tags: ["payments"],
    description: "Paid operations, newest first, with their items grouped."

  alias Nexo.Billing.Payments
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    subject
    |> Payments.history(student)
    |> UpstreamReply.reply()
  end
end
