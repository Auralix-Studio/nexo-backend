defmodule Nexo.Web.DirectoryController do
  @moduledoc "Legacy student directory, its access grants and guardian links (`/api/v1/directory`)."
  use Nexo.Web, :controller

  alias Nexo.Academic.Directory
  alias Nexo.Access.DirectoryAccess
  alias Nexo.People.Guardians
  alias Nexo.Security.Audit
  alias Nexo.Web.ClientIp

  @doc "Whether this account may open the directory; the app asks on start."
  def access(conn, _params) do
    actor = conn.assigns.current_actor
    role = DirectoryAccess.role(actor.code)

    json(conn, %{
      acceso: role != nil,
      rol: role && to_string(role),
      codigo: actor.code,
      tipo: to_string(actor.type)
    })
  end

  def index(conn, params) do
    page =
      Directory.list(
        query: params["q"],
        school: params["escuela"],
        cycle: to_int(params["ciclo"]),
        page: to_int(params["pagina"]) || 1,
        limit: to_int(params["limite"]) || 25
      )

    json(conn, %{
      estudiantes: Enum.map(page.students, &summary_view/1),
      total: page.total,
      pagina: page.page,
      paginas: page.pages
    })
  end

  def schools(conn, _params), do: json(conn, %{escuelas: Directory.schools()})

  def show(conn, %{"codigo" => code}) do
    case Directory.get(code) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no_encontrado"})

      record ->
        actor = conn.assigns.current_actor

        # Opening a person's record is audited by name: it is the access that
        # has to be justified later.
        Audit.log(:directory_record_read, %{
          actor_type: to_string(actor.type),
          actor_id: actor.code,
          student_code: code,
          detail: %{rol: to_string(conn.assigns[:directory_role])},
          ip: ClientIp.get(conn)
        })

        json(conn, %{estudiante: record_view(record)})
    end
  end

  # --- Access administration -------------------------------------------------

  def grants(conn, _params) do
    json(conn, %{
      accesos: Enum.map(DirectoryAccess.list(), &grant_view/1),
      administradores: DirectoryAccess.system_admins()
    })
  end

  def set_grant(conn, %{"codigo" => code} = params) do
    case DirectoryAccess.set_status(code, params["estado"] || "activo", actor(conn),
           note: params["nota"],
           ip: ClientIp.get(conn)
         ) do
      {:ok, grant} -> json(conn, %{acceso: grant_view(grant)})
      {:error, :invalid_status} -> unprocessable(conn, "estado_invalido")
    end
  end

  # --- Guardians (administration) ---------------------------------------------

  def guardians(conn, _params) do
    json(conn, %{apoderados: Enum.map(Guardians.list(), &guardian_view/1)})
  end

  @doc """
  Links (or updates) a guardian with their students. A new PIN is returned
  **only here, once**: it is not stored in clear anywhere.
  """
  def set_guardian(conn, %{"dni" => dni} = params) do
    opts = [actor: actor(conn), ip: ClientIp.get(conn)]

    if params["estado"] == "revocado" do
      {:ok, guardian} = Guardians.revoke(dni, opts)
      json(conn, %{apoderado: guardian_view(guardian)})
    else
      opts = opts ++ [name: params["nombre"], reset_pin: params["nuevo_pin"] == true]

      case Guardians.link(dni, params["estudiantes"] || [], opts) do
        {:ok, guardian, pin} -> json(conn, %{apoderado: guardian_view(guardian), pin: pin})
        {:error, :invalid_dni} -> unprocessable(conn, "dni_invalido")
      end
    end
  end

  # --- Views -----------------------------------------------------------------

  def summary_view(s) do
    %{
      codigo: s.code,
      nombres: s.first_name,
      apellidos: s.last_name,
      escuela: s.school,
      ciclo: s.cycle,
      condicion: s.status,
      promedio: s.average,
      creditos_aprobados: s.credits_approved,
      creditos_totales: s.credits_total
    }
  end

  def record_view(r) do
    r
    |> summary_view()
    |> Map.merge(%{
      dni: r.dni,
      correo: r.email,
      telefono: r.phone,
      facultad: r.faculty,
      plan: r.plan,
      anio_ingreso: r.entry_year,
      academico: r.academic,
      modulos: r.modules,
      actualizado: r.updated_at
    })
  end

  defp grant_view(grant) do
    %{
      codigo: grant["code"],
      estado: grant["status"],
      nota: grant["note"],
      concedido_por: grant["granted_by"],
      concedido_en: grant["granted_at"],
      revocado_en: grant["revoked_at"],
      actualizado_en: grant["updated_at"]
    }
  end

  defp guardian_view(g) do
    %{
      dni: g["dni"],
      nombre: g["name"],
      estudiantes: g["students"] || [],
      estado: g["status"],
      bloqueado: Guardians.locked?(g),
      ultimo_acceso: g["last_access_at"],
      actualizado_en: g["updated_at"]
    }
  end

  defp actor(conn), do: conn.assigns.current_actor.code

  defp unprocessable(conn, error),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: error})

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil
end
