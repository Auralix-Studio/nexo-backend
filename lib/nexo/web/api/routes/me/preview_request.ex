defmodule Nexo.Web.Api.Routes.Me.PreviewRequest do
  use Nexo.Web.Api.Route,
    name: "me.connections.preview",
    method: :get,
    path: "/me/connections/requests/:code",
    auth: [:student],
    rate_limit: {30, 600},
    params: [code: [type: :string, format: "^[A-Za-z-]{8,9}$"]],
    tags: ["integrations"],
    description: "Which app asks for access and to what, for the consent screen."

  @impl true
  def handle(_conn, %{code: code}) do
    case Nexo.Integrations.Connections.preview(code) do
      {:ok, preview} -> {:ok, preview}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
