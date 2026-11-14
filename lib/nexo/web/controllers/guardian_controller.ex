defmodule Nexo.Web.GuardianController do
  @moduledoc "Legacy guardian access: DNI + PIN login and their children's records."
  use Nexo.Web, :controller

  alias Nexo.Academic.Directory
  alias Nexo.Infra.Db
  alias Nexo.People.Guardians
  alias Nexo.Security.{Audit, Auth}
  alias Nexo.Web.{ClientIp, DirectoryController}

  def login(conn, %{"dni" => dni, "pin" => pin}) when is_binary(dni) and is_binary(pin) do
    dni = String.trim(dni)

    case Guardians.verify(dni, String.trim(pin)) do
      {:ok, guardian} ->
        id = Db.id_to_string(guardian["_id"])
        students = Guardians.students(guardian)
        audit(conn, :guardian_login, guardian["dni"])

        json(conn, %{
          access_token: Auth.sign_access_token(:guardian, id),
          refresh_token: Auth.issue_refresh_token(:guardian, id),
          expires_in: Auth.access_ttl_seconds(),
          apoderado: %{
            dni: guardian["dni"],
            nombre: guardian["name"],
            estudiantes: length(students)
          },
          estudiantes:
            for(
              code <- students,
              s = Directory.get(code),
              do: DirectoryController.summary_view(s)
            )
        })

      {:error, :locked} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: "acceso_bloqueado",
          detail: "Demasiados intentos. Espera unos minutos y vuelve a probar."
        })

      {:error, :invalid} ->
        audit(conn, :guardian_login_failed, dni)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "credenciales_invalidas", detail: "DNI o PIN incorrectos."})
    end
  end

  def login(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "parametros_invalidos"})
  end

  @doc "A child's record: only the guardian's own, and every opening is audited."
  def show(conn, %{"codigo" => code}) do
    guardian = conn.assigns.current_guardian

    cond do
      not Guardians.linked?(guardian, code) ->
        audit(conn, :guardian_access_denied, guardian["dni"], code)

        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "estudiante_ajeno",
          detail: "Solo puedes ver la ficha de tus hijos o tutelados."
        })

      record = Directory.get(code) ->
        audit(conn, :guardian_record_read, guardian["dni"], code)
        json(conn, %{estudiante: DirectoryController.record_view(record)})

      true ->
        conn |> put_status(:not_found) |> json(%{error: "no_encontrado"})
    end
  end

  defp audit(conn, action, dni, student_code \\ nil) do
    attrs = %{actor_type: "guardian", actor_id: dni, ip: ClientIp.get(conn)}

    Audit.log(
      action,
      if(student_code, do: Map.put(attrs, :student_code, student_code), else: attrs)
    )
  end
end
