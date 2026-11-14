defmodule Nexo.Web.Api.Routes.Account.Me do
  use Nexo.Web.Api.Route,
    name: "account.me",
    method: :get,
    path: "/me",
    auth: [:teacher, :student, :guardian],
    tags: ["account"],
    description: "Who the token belongs to: subject type and basic profile."

  # Only identification fields leave the server; anything else stored on the
  # record (PIN hashes, lockout counters, consent details) stays inside.
  @public_fields ~w(code first_name last_name name status)

  @impl true
  def handle(conn, _params) do
    %{type: type, id: id, record: record} = conn.assigns.current_subject
    {:ok, %{type: type, id: id, profile: Map.take(record, @public_fields)}}
  end
end
