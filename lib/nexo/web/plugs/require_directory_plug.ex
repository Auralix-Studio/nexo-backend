defmodule Nexo.Web.RequireDirectoryPlug do
  @moduledoc """
  Exige acceso vigente al directorio de estudiantes. Se relee en cada
  petición: revocar el acceso surte efecto al instante, sin esperar a que
  caduque el token.
  """
  import Plug.Conn
  alias Nexo.Access.DirectoryAccess

  def init(opts), do: opts

  def call(%{assigns: %{current_actor: %{code: code}}} = conn, opts) do
    case DirectoryAccess.role(code) do
      nil ->
        denied(conn)

      :autorizado when opts == [:admin] ->
        denied(conn, "solo_administradores", "Esta acción es de administradores.")

      role ->
        assign(conn, :directory_role, role)
    end
  end

  def call(conn, _opts), do: Nexo.Web.AuthPlug.unauthorized(conn)

  defp denied(
         conn,
         error \\ "sin_acceso_directorio",
         detail \\ "Tu cuenta no tiene acceso al directorio de estudiantes."
       ) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: error, detail: detail})
    |> halt()
  end
end
