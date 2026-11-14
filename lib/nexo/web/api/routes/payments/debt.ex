defmodule Nexo.Web.Api.Routes.Payments.Debt do
  use Nexo.Web.Api.Route,
    name: "payments.debt",
    method: :get,
    path: "/payments",
    auth: [:student],
    tags: ["payments"],
    description:
      "What the student owes: overdue and pending charges with a status from the due date, " <>
        "fees and totals."

  alias Nexo.Billing.Payments
  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    %{record: student} = subject = conn.assigns.current_subject

    subject
    |> Payments.debt(student)
    |> UpstreamReply.reply()
  end
end
