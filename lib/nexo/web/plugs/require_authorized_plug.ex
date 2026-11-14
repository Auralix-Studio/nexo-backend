defmodule Nexo.Web.RequireAuthorizedPlug do
  @moduledoc "Solo docentes con allowlist activa (`status: \"autorizado\"`)."
  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_teacher: %{"status" => "autorizado"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: "no_autorizado",
      detail: "Tu acceso aún no fue aprobado."
    })
    |> halt()
  end
end
