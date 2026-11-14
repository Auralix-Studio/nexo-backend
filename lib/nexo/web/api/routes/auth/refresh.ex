defmodule Nexo.Web.Api.Routes.Auth.Refresh do
  use Nexo.Web.Api.Route,
    name: "auth.refresh",
    method: :post,
    path: "/auth/refresh",
    auth: :public,
    rate_limit: {30, 600},
    params: [refresh_token: [type: :string, required: true, max: 256]],
    tags: ["auth"],
    description: "Exchanges a refresh token (single use) for a new access token."

  alias Nexo.Security.Auth

  @impl true
  def handle(_conn, %{refresh_token: raw}) do
    case Auth.exchange_refresh_token(raw) do
      {:ok, %{type: type, id: id, new_refresh: refresh}} ->
        {:ok,
         %{
           access_token: Auth.sign_access_token(type, id),
           refresh_token: refresh,
           expires_in: Auth.access_ttl_seconds()
         }}

      {:error, _} ->
        {:error, :unauthorized}
    end
  end
end
