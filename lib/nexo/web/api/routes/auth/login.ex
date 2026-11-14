defmodule Nexo.Web.Api.Routes.Auth.Login do
  use Nexo.Web.Api.Route,
    name: "auth.login",
    method: :post,
    path: "/auth/login",
    auth: :public,
    rate_limit: {60, 600},
    params: [
      user: [type: :string, required: true, min: 3, max: 32],
      password: [type: :string, required: true, min: 1, max: 128]
    ],
    tags: ["auth"],
    description:
      "Logs in with university credentials and opens the SIGMA, Intranet and Language Center sessions."

  alias Nexo.Upstream.Login

  @impl true
  def handle(conn, %{user: user, password: password}) do
    case Login.login(user, password, %{ip: conn.assigns.client_ip}) do
      {:ok, session} -> {:ok, session}
      {:error, :invalid_credentials} -> {:error, :invalid_credentials}
      {:error, _} -> {:error, :upstream_unavailable}
    end
  end
end
