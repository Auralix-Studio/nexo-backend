defmodule Nexo.Web.Api.Routes.Auth.ChangePassword do
  use Nexo.Web.Api.Route,
    name: "auth.change_password",
    method: :post,
    path: "/auth/password",
    auth: [:student, :teacher],
    rate_limit: {5, 600},
    params: [
      current_password: [type: :string, required: true, format: "^.{1,128}$"],
      new_password: [type: :string, required: true, format: "^.{6,128}$"]
    ],
    tags: ["auth"],
    description:
      "Changes the university password through SIGMA. Nothing is stored; the app keeps the new one on the device."

  alias Nexo.Security.Password

  @impl true
  def handle(conn, %{current_password: current, new_password: new}) do
    case Password.change(conn.assigns.current_subject, current, new) do
      :ok ->
        {:ok, %{changed: true}}

      {:error, :rejected, message} ->
        {:error, 422, :password_rejected, message || "The university did not accept the change."}

      {:error, :reauth_required} ->
        {:error, :reauth_required}

      {:error, _} ->
        {:error, :upstream_unavailable}
    end
  end
end
