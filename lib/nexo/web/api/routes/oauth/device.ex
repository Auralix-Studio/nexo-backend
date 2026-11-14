defmodule Nexo.Web.Api.Routes.OAuth.Device do
  use Nexo.Web.Api.Route,
    name: "oauth.device",
    method: :post,
    path: "/oauth/device",
    auth: :public,
    attest: false,
    rate_limit: {20, 600},
    params: [
      client_id: [type: :string, required: true, max: 64],
      scope: [type: :string, required: true, max: 64]
    ],
    tags: ["integrations"],
    description: "Starts a Connect with Nexo request (RFC 8628). Scopes: profile, schedule."

  alias Nexo.Integrations.Connections
  alias Nexo.Web.Api.Routes.OAuth.OAuthResponse

  @impl true
  def handle(conn, %{client_id: client_id, scope: scope}) do
    case Connections.start(client_id, scope) do
      {:ok, body} -> OAuthResponse.ok(conn, body)
      {:error, code} -> OAuthResponse.error(conn, code)
    end
  end
end
