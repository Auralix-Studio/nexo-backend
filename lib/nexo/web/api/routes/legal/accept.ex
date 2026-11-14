defmodule Nexo.Web.Api.Routes.Legal.Accept do
  use Nexo.Web.Api.Route,
    name: "legal.accept",
    method: :post,
    path: "/me/legal/accept",
    auth: [:student, :teacher, :guardian],
    rate_limit: {20, 3600},
    params: [version: [type: :integer, required: true, min: 1]],
    tags: ["legal"],
    description:
      "Records that the user accepted a version of the legal documents (kept as evidence)."

  @impl true
  def handle(conn, %{version: version}) do
    meta = %{
      ip: conn.assigns.client_ip,
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    }

    case Nexo.Legal.accept(conn.assigns.current_subject, version, meta) do
      {:ok, accepted} ->
        {:ok, accepted}

      {:error, :unknown_version} ->
        {:error, 422, :unknown_version, "That version of the legal documents does not exist."}
    end
  end
end
