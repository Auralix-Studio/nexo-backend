defmodule Nexo.SigmaMock do
  @moduledoc """
  SIGMA simulado para los tests.

  Cuentas:

  - `"D001"`/`"ok"` → docente con las secciones `S-1` y `S-2`
  - `"D002"`/`"ok"` → otro docente, con la sección `S-9` (sirve para comprobar
    que nadie alcanza secciones ajenas)
  - `"E001"`/`"ok"` → estudiante (no docente)
  - `"down"` → SIGMA caído
  - clave `"expirado"` → devuelve un token que SIGMA ya no acepta
  """
  @behaviour Nexo.Sigma

  @sections %{
    "tok-D001" => [
      %{
        id: "S-1",
        code: "332123",
        subject: "ALGEBRA LINEAL",
        section: "A1",
        periodo: "2026-I",
        enrolled: 2
      },
      %{
        id: "S-2",
        code: "332124",
        subject: "CALCULO II",
        section: "B2",
        periodo: "2026-I",
        enrolled: 1
      }
    ],
    "tok-D002" => [
      %{
        id: "S-9",
        code: "339999",
        subject: "REDES",
        section: "C1",
        periodo: "2026-I",
        enrolled: 1
      }
    ]
  }

  @students %{
    "S-1" => [
      %{code: "E001", first_name: "José", last_name: "Rojas", attendance: "100", grade: "15"},
      %{code: "E002", first_name: "Ana", last_name: "Flores", attendance: "90", grade: "11.60"}
    ],
    "S-2" => [
      %{code: "E003", first_name: "Luis", last_name: "Pérez", attendance: "80", grade: "13"}
    ],
    "S-9" => [
      %{code: "E004", first_name: "Rosa", last_name: "Díaz", attendance: "95", grade: "17"}
    ]
  }

  @impl true
  def verify_login("down", _), do: {:error, :unavailable}

  def verify_login("D001", "expirado") do
    {:ok, profile("D001", "María", "Quispe", "tok-vencido")}
  end

  def verify_login("D001", "ok"), do: {:ok, profile("D001", "María", "Quispe", "tok-D001")}
  # Documento incluido en AUTHORIZED_TEACHERS (ver config/test.exs).
  def verify_login("PRE-001", "ok"), do: {:ok, profile("PRE-001", "Elena", "Vargas", "tok-D001")}
  def verify_login("D002", "ok"), do: {:ok, profile("D002", "Carlos", "Ramos", "tok-D002")}

  # Estudiante cuyo código está en SYSTEM_ADMINS (ver config/test.exs): puede
  # repartir el acceso al directorio.
  def verify_login("ADMIN-SYS", "ok") do
    {:ok,
     %{
       code: "62017241",
       first_name: "Coordinación",
       last_name: "Académica",
       teacher?: false,
       token: "tok-ADMIN"
     }}
  end

  def verify_login("E001", "ok") do
    {:ok,
     %{code: "E001", first_name: "José", last_name: "Rojas", teacher?: false, token: "tok-E001"}}
  end

  def verify_login("E004", "ok") do
    {:ok,
     %{code: "E004", first_name: "Rosa", last_name: "Díaz", teacher?: false, token: "tok-E004"}}
  end

  def verify_login(_, _), do: {:error, :invalid_credentials}

  @impl true
  def list_sections("tok-vencido"), do: {:error, :session_expired}
  def list_sections(token), do: {:ok, Map.get(@sections, token, [])}

  @impl true
  def list_section_students("tok-vencido", _), do: {:error, :session_expired}
  def list_section_students(_token, cle_auto), do: {:ok, Map.get(@students, cle_auto, [])}

  @impl true
  def section_grades("tok-vencido", _, _), do: {:error, :session_expired}
  def section_grades(_token, cle_auto, _unit), do: {:ok, Map.get(@students, cle_auto, [])}

  # Teacher module calls (reads and writes) live in their own mock.
  @impl true
  defdelegate call(token, method, path, query, body), to: Nexo.SigmaTeacherMock

  @impl true
  defdelegate download(token, path, query), to: Nexo.SigmaTeacherMock

  # Shapes copied from SIGMA's student endpoints, values made up: numbers as
  # strings, padded cycles, upper-case names, the "active" flag.
  @impl true
  def fetch("tok-vencido", _path), do: {:error, :session_expired}

  def fetch("tok-E001", "/Estudiante/MostrarInfoEstudiante") do
    {:ok,
     [
       %{
         "est_Id" => "E001",
         "estudiante" => "ROJAS QUISPE JOSE",
         "carrera" => "INGENIERÍA DE SISTEMAS Y COMPUTACIÓN",
         "facultad" => "INGENIERÍA",
         "sede" => "HUANCAYO",
         "nivel" => "7",
         "pes_Id" => "2015",
         "modalidad" => "PRESENCIAL",
         "matriculado" => true,
         "ultimaMatricula" => "2026-2",
         "creditoAprobado" => "168"
       }
     ]}
  end

  def fetch("tok-E001", "/Estudiante/MostrarNotasResumen/2015/7") do
    {:ok,
     %{
       "promedio" => "14.1234",
       "creditosAprobados" => "168",
       "creditosTotales" => "220",
       "cantMatricula" => 13
     }}
  end

  def fetch("tok-E001", "/Recursos/ListarPeriodosEstudiante") do
    {:ok,
     [
       %{
         "periodoId" => "20262",
         "descripcion" => "2026 - II",
         "anio" => 2026,
         "periodo" => "2",
         "activo" => true
       },
       %{
         "periodoId" => "20261",
         "descripcion" => "2026 - 1",
         "anio" => 2026,
         "periodo" => 1,
         "activo" => false
       }
     ]}
  end

  # SIGMA's schedule names the teacher `docente` and types labs `L`.
  def fetch("tok-E004", "/Intranet/ListarHorariosEstudianteIntranet/*/*") do
    {:ok,
     [
       %{
         "id" => "IS-401",
         "nrc" => "341200",
         "asignatura" => "SISTEMAS OPERATIVOS",
         "seccion" => "A1",
         "idDia" => 2,
         "dia" => "Martes",
         "horaInicio" => "16:45",
         "horaFin" => "19:00",
         "sede" => "HUANCAYO",
         "local" => "PABELLON J",
         "aula" => "LAB 3",
         "docente" => "QUISPE ROJAS LUIS",
         "idTipo" => "L",
         "modalidad" => "PRESENCIAL"
       }
     ]}
  end

  # Term averages come as strings, in no particular order.
  def fetch("tok-E001", "/Estudiante/ListarPromediosResumen") do
    {:ok,
     [
       %{"anio" => "2025", "periodo" => "2", "promedio" => "14.4000"},
       %{"anio" => "2026", "periodo" => "1", "promedio" => "13.8"},
       %{"anio" => "2026", "periodo" => "2", "promedio" => "0"}
     ]}
  end

  # Legacy grades keyed by name: a make-up exam lifted the final to 11.
  def fetch("tok-E004", "/Intranet/ListarNotasEstudianteIntranet/2025/2") do
    {:ok,
     [
       %{
         "codigo" => "IS-150",
         "asignatura" => "FISICA I",
         "ciclo" => "02",
         "seccion" => "B1",
         "credito" => "3.000",
         "asistencia" => "80",
         "pF1" => "9",
         "pF2" => "9",
         "pf" => "9",
         "complementario" => "12",
         "pfp" => "11",
         "cc" => "True",
         "tipoAsignatura" => "TN",
         "puesto" => "     "
       }
     ]}
  end

  # Publications as captured (one image), plus one without a URL to drop.
  def fetch("tok-E001", "/Recursos/ListarPublicaciones") do
    {:ok,
     [
       %{
         "idPublicacion" => 1009,
         "tipoContenido" => "image",
         "urlPrincipal" => "https://sigma.upla.edu.pe/Recursos/Imagenes/Anuncios/a.jpeg",
         "urlAdaptable" => nil,
         "orientacion" => nil,
         "urlReferencia" => " ",
         "textoBoton" => nil,
         "permiteDescarga" => false,
         "dimensionPrincipal" => "1080x1350",
         "dimensionAdaptable" => nil
       },
       %{"idPublicacion" => 1010, "tipoContenido" => "image", "urlPrincipal" => ""}
     ]}
  end

  # Wi-Fi keys are unconfirmed; the app read `usuario`/`contrasena`.
  def fetch("tok-E001", "/Recursos/ObtenerWifiUsuario") do
    {:ok, %{"usuario" => "u-e001", "contrasena" => "wifi-secret"}}
  end

  def fetch(_token, _path), do: {:ok, nil}

  defp profile(code, first, last, token) do
    %{code: code, first_name: first, last_name: last, teacher?: true, token: token}
  end
end
