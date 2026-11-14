defmodule Nexo.SigmaTeacherMock do
  @moduledoc """
  SIGMA's teacher endpoints for tests (`Docente/*`, `Asignatura/*`), with the
  shapes the official web client reads; values made up. Teacher `"D001"`
  (`tok-D001`). Every write is also sent to the calling process as
  `{:sigma_post, path, query, body}` so tests can check the payload.
  """

  def call("tok-vencido", _method, _path, _query, _body), do: {:error, :session_expired}

  def call("tok-D001", :get, "/Docente/GetAsignaturaDocente", %{"modo" => "Notas"}, _) do
    section = %{
      "id" => "9001",
      "nrc" => "341119",
      "asignatura" => "BASE DE DATOS I (2026-2)",
      "seccion" => "A2",
      "carrera" => "INGENIERIA DE SISTEMAS",
      "plan" => "2015",
      "tipoCalif" => 0,
      "matriculados" => 2
    }

    ok([
      section,
      # SIGMA repeats sections within one list.
      section,
      %{
        "id" => "9002",
        "nrc" => "341120",
        "asignatura" => "INTERNET DE LAS COSAS (ELECTIVO)",
        "seccion" => "B1",
        "carrera" => "INGENIERIA DE SISTEMAS",
        "tipoCalif" => 12
      }
    ])
  end

  def call("tok-D001", :get, "/Docente/GetAsignaturaDocente", %{"modo" => "Asistencia"}, _) do
    ok([
      %{
        "id" => "419329, 419321",
        "nrc" => "341119",
        "seccion" => "A2",
        "carrera" => "INGENIERIA DE SISTEMAS - PRESENCIAL",
        "modalidad" => "PRESENCIAL",
        "sede" => "HU",
        "aula" => "PABELLON K - K 101 - AFORO: 40",
        "ciclo" => "04",
        "plan" => "2015",
        "horario" => "Jueves 11:30:00 13:00:00 P, Martes 16:45:00 19:00:00 T"
      }
    ])
  end

  def call("tok-D001", :get, "/Docente/NotasEstudianteResumenV1", %{"cleAuto" => "9001"} = q, _) do
    # tipoCalif 0 must be sent as 12.
    "12" = q["tipoCalificacion"]

    ok([
      %{
        "codigo" => "U001",
        "nombreCompleto" => "ROJAS QUISPE ANA",
        "asistencia" => "82.5",
        "notaFinal" => "13",
        "matricula_asignatura_id" => "M1",
        "observacion" => "",
        "unidades" => [
          %{
            "unidadId" => 101,
            "nombre" => "UNIDAD 1",
            "porcentaje" => 25,
            "promedioUnidad" => 14,
            "grupos" => [
              %{
                "idTipoNota" => 12,
                "tipoNotaAbr" => "DE",
                "peso" => 40,
                "notas" => [%{"idNota" => 501, "valor" => 14}]
              },
              %{
                "idTipoNota" => 11,
                "tipoNotaAbr" => "EV",
                "peso" => 30,
                "notas" => [%{"idNota" => 500, "valor" => 15}]
              }
            ]
          }
        ]
      },
      %{
        "codigo" => "U002",
        "nombreCompleto" => "PEREZ LUIS",
        "asistencia" => "60",
        "notaFinal" => "0",
        "matricula_asignatura_id" => "M2",
        "observacion" => "SUSPENSIÓN",
        "unidades" => [
          %{
            "unidadId" => 101,
            "nombre" => "UNIDAD 1",
            "porcentaje" => 25,
            "grupos" => [
              %{"idTipoNota" => 11, "tipoNotaAbr" => "EV", "peso" => 30, "notas" => []}
            ]
          }
        ]
      }
    ])
  end

  # Grades screen: cursal 0 and the section id.
  def call("tok-D001", :get, "/Asignatura/getTipoUnidadesV2", %{"cle_auto" => "9001"} = q, _) do
    "0" = q["cursal"]
    "12" = q["tipoCalif"]

    ok([
      %{"tipo_unidad_id" => 101, "descripcion" => "UNIDAD 1", "habilitado" => true},
      %{"tipo_unidad_id" => 102, "descripcion" => "UNIDAD 2", "habilitado" => false},
      %{"tipo_unidad_id" => 0, "descripcion" => ""}
    ])
  end

  # Attendance screen: the first schedule id as cursal, cle_auto 0.
  def call("tok-D001", :get, "/Asignatura/getTipoUnidadesV2", %{"cle_auto" => "0"} = q, _) do
    "419329" = q["cursal"]

    ok([
      %{"tipo_unidad_id" => 201, "descripcion" => "UNIDAD 2", "habilitado" => "1"},
      %{"tipo_unidad_id" => 212, "descripcion" => "INTERNA"}
    ])
  end

  def call("tok-D001", :get, "/Asignatura/getTipoNota", %{"tipoUnidad" => "101"}, _) do
    ok([
      %{
        "tipo_nota_id" => 11,
        "tipo_nota_abr" => "EV",
        "tipo_nota_desc" => "EVIDENCIA DE CONOCIMIENTO",
        "tipo_nota_escala" => "0 - 20    ",
        "minimo_aprob" => 10.5,
        "tipo_nota_cant_max" => 2,
        "tipo_nota_color" => "#4F46E5"
      }
    ])
  end

  def call("tok-D001", :get, "/Docente/GetAsistencia", q, _) do
    "419329, 419321" = q["codSaltem"]
    "341119" = q["asignID"]

    ok([
      %{
        "codigo" => "U001",
        "nombreCompleto" => "ROJAS QUISPE ANA",
        "matricula_asignatura_id" => "M1",
        "cod_cursal" => "419329, 419321",
        "observacion" => "",
        "asistencia" => "82.5",
        "detalle" => [
          %{
            "asistencia_id" => 7001,
            "fecha_asistencia" => "2026-10-29 14:41:0",
            "estado_asist_id" => 1,
            "tipo_unidad_id" => 201
          }
        ]
      },
      %{
        "codigo" => "U002",
        "nombreCompleto" => "PEREZ LUIS",
        "matricula_asignatura_id" => "M2",
        "cod_cursal" => "419329",
        "observacion" => "Suspensión",
        "asistencia" => "60",
        "detalle" => [
          %{
            "asistencia_id" => 7002,
            "fecha_asistencia" => "2026-10-29 14:41:00",
            "estado_asist_id" => 4,
            "tipo_unidad_id" => 201
          }
        ]
      }
    ])
  end

  def call("tok-D001", :get, "/Docente/GetHora", _, _),
    do: ok("2026-11-05T09:05:07.9331277-05:00")

  # Shape read by the app from `Login/GetDatosEntidad`: upper-case names with
  # padding, the post under `dependencia`.
  def call("tok-D001", :get, "/Login/GetDatosEntidad", _, _) do
    ok(%{
      "codigo" => "D001",
      "nombres" => " JUAN CARLOS ",
      "apellidos" => "PEREZ ROJAS",
      "dependencia" => %{"facultad" => "INGENIERIA", "cargo" => "DOCENTE ORDINARIO"}
    })
  end

  def call("tok-D001", :get, "/Docente/getAsistenciaDocente", _, _) do
    ok([
      %{
        "codigo" => "C123",
        "asignatura" => "BASE DE DATOS I (2026-2)",
        "car_Id" => "SISTEMAS",
        "seccion" => "A2",
        "hora_ini" => "08:00:00",
        "hora_fin" => "09:45:00",
        "tol_ini" => 10,
        "tol_fin" => 15,
        "marc_entrada" => "07:58:00",
        "marc_salida" => "00:00:00"
      }
    ])
  end

  def call("tok-D001", :get, "/Docente/getHistorialMarcacion", _, _) do
    ok([
      %{
        "fecha" => "2026-10-07T00:00:00",
        "hora" => "07:58:00",
        "idDia" => 3,
        "dia" => "Miércoles",
        "modo" => "Entrada",
        "ubcacionMarcador" => "VIRTUAL "
      }
    ])
  end

  # `pagina` is ignored upstream: every page repeats the same rows.
  def call("tok-D001", :get, "/Docente/getAsistenciaDiaria", _, _) do
    row = %{
      "fecha" => "10/07/2026 00:00:00",
      "idDia" => 3,
      "asignatura" => "BASE DE DATOS I (2026-2)",
      "seccion" => "A2",
      "horaInicio" => "08:00:00",
      "horaFin" => "09:45:00",
      "modalidad" => "PRESENCIAL",
      "statusInicio" => "1",
      "statusFin" => "X"
    }

    ok([row, row])
  end

  def call("tok-D001", :post, path, query, body) do
    send(self(), {:sigma_post, path, query, body})

    message =
      if path == "/Docente/InsertaRegistroAsistenciaDocente",
        do: "S - Salida registrada",
        else: "OK"

    {:ok, %{success: true, data: nil, message: message}}
  end

  def call(_token, :get, _path, _query, _body), do: ok([])

  @doc "Reports: the query is sent back to the test process to check it."
  def download("tok-vencido", _path, _query), do: {:error, :session_expired}

  def download("tok-D001", "/Docente/GetReporteAuxiliar", query) do
    send(self(), {:sigma_download, query})

    type =
      if query["tipo"] == "xlsx",
        do: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        else: "application/pdf"

    {:ok, %{body: "%PDF-fake " <> query["tipo"], content_type: type, filename: nil}}
  end

  def download(_token, _path, _query), do: {:error, :unavailable}

  defp ok(data), do: {:ok, %{success: true, data: data, message: nil}}
end
