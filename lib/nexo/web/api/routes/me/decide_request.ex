defmodule Nexo.Web.Api.Routes.Me.DecideRequest do
  use Nexo.Web.Api.Route,
    name: "me.connections.decide",
    method: :post,
    path: "/me/connections/requests/:code",
    auth: [:student],
    rate_limit: {30, 600},
    params: [
      code: [type: :string, format: "^[A-Za-z-]{8,9}$"],
      decision: [type: :string, required: true, in: ["approve", "deny"]]
    ],
    tags: ["integrations"],
    description: "Approves or denies an app's request. Approving needs shared data to exist."

  alias Nexo.Integrations.{Connections, SharedData}

  @impl true
  def handle(conn, %{code: code, decision: decision}) do
    id = conn.assigns.current_subject.id

    cond do
      decision == "approve" and SharedData.get(id) == :none ->
        {:error, 409, :nothing_shared, "Share your profile or schedule first."}

      Connections.decide(code, id, String.to_existing_atom(decision), %{
        ip: conn.assigns.client_ip
      }) == :ok ->
        {:ok, %{decision: decision}}

      true ->
        {:error, :not_found}
    end
  end
end
