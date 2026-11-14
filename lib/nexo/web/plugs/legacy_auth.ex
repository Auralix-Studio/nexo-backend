defmodule Nexo.Web.LegacyAuth do
  @moduledoc """
  Authentication of the legacy `/api/v1` directory and guardian routes.

    * `:actor` — a teacher or student token; leaves `:current_actor`
      (`type`, `code`, names). Guardians are not directory actors.
    * `:guardian` — an active guardian's token; leaves `:current_guardian`.
    * `{:directory, roles}` — after `:actor`, requires directory access
      (`[:admin]` for administration); leaves `:directory_role`.

  Records and access are reloaded on every request, so a revocation takes
  effect at once, not when the token expires.
  """
  import Plug.Conn
  alias Nexo.Access.DirectoryAccess
  alias Nexo.People.{Guardians, Students, Teachers}
  alias Nexo.Security.Auth

  def init(opts), do: opts

  def call(conn, :actor) do
    case subject(conn) do
      {:teacher, id} -> assign_actor(conn, :teacher, Teachers.get_teacher(id), "sigma_code")
      {:student, id} -> assign_actor(conn, :student, Students.get(id), "code")
      _ -> unauthorized(conn)
    end
  end

  def call(conn, :guardian) do
    with {:guardian, id} <- subject(conn),
         %{} = guardian <- Guardians.get(id),
         true <- Guardians.active?(guardian) do
      assign(conn, :current_guardian, guardian)
    else
      _ -> unauthorized(conn)
    end
  end

  def call(%{assigns: %{current_actor: %{code: code}}} = conn, {:directory, roles}) do
    case DirectoryAccess.role(code) do
      nil ->
        forbidden(
          conn,
          "sin_acceso_directorio",
          "Tu cuenta no tiene acceso al directorio de estudiantes."
        )

      :autorizado when roles == [:admin] ->
        forbidden(conn, "solo_administradores", "Esta acción es de administradores.")

      role ->
        assign(conn, :directory_role, role)
    end
  end

  def call(conn, {:directory, _roles}), do: unauthorized(conn)

  defp subject(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{type: type, id: id}} <- Auth.verify_access_token(token),
         do: {type, id}
  end

  defp assign_actor(conn, _type, nil, _code_key), do: unauthorized(conn)

  defp assign_actor(conn, type, record, code_key) do
    assign(conn, :current_actor, %{
      type: type,
      code: record[code_key],
      first_name: record["first_name"],
      last_name: record["last_name"]
    })
  end

  defp unauthorized(conn), do: reply(conn, 401, %{error: "no_autenticado"})

  defp forbidden(conn, error, detail), do: reply(conn, 403, %{error: error, detail: detail})

  defp reply(conn, status, body) do
    conn |> put_status(status) |> Phoenix.Controller.json(body) |> halt()
  end
end
