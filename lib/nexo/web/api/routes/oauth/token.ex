defmodule Nexo.Web.Api.Routes.OAuth.Token do
  use Nexo.Web.Api.Route,
    name: "oauth.token",
    method: :post,
    path: "/oauth/token",
    auth: :public,
    attest: false,
    rate_limit: {120, 600},
    params: [
      grant_type: [type: :string, required: true, max: 64],
      client_id: [type: :string, required: true, max: 64],
      device_code: [type: :string, max: 128],
      refresh_token: [type: :string, max: 128]
    ],
    tags: ["integrations"],
    description: "Exchanges an approved device code, or a refresh token, for access tokens."

  alias Nexo.Integrations.Connections
  alias Nexo.Web.Api.Routes.OAuth.OAuthResponse

  @device_grant "urn:ietf:params:oauth:grant-type:device_code"

  @impl true
  def handle(conn, %{grant_type: @device_grant, client_id: client_id} = params) do
    respond(conn, Connections.exchange_device_code(client_id, params[:device_code]))
  end

  def handle(conn, %{grant_type: "refresh_token", client_id: client_id} = params) do
    respond(conn, Connections.refresh(client_id, params[:refresh_token]))
  end

  def handle(conn, _params), do: OAuthResponse.error(conn, :unsupported_grant_type)

  defp respond(conn, {:ok, tokens}), do: OAuthResponse.ok(conn, tokens)
  defp respond(conn, {:error, code}), do: OAuthResponse.error(conn, code)
end
