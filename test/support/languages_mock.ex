defmodule Nexo.LanguagesMock do
  @moduledoc """
  Language Center stand-in for tests: only `E001` is enrolled, in a course of
  the current month (raw key names, `0` meaning "no grade").
  """
  @behaviour Nexo.Upstream.Languages

  @impl true
  def login("E001", "ok"), do: {:ok, "lang-E001"}
  def login(_, _), do: {:error, :invalid_credentials}

  @impl true
  def get("lang-E001", "/Matricula/ListarMisAsignaturasMatriculadas/E001") do
    today = Date.utc_today()

    {:ok,
     [
       %{
         "asigId" => "ING-B1",
         "asignatura" => "INGLÉS B1",
         "dias" => "LU-MI",
         "horaInicio" => "19:00:00",
         "horaFin" => "20:30:00",
         "aula" => "5",
         "aulaNombre" => "Aula 5",
         "detMatriculaId" => 555,
         "modalidad" => "VIRTUAL",
         "idiomaNombre" => "INGLÉS",
         "seccion" => "B",
         "anio" => today.year,
         "mes" => today.month,
         "tipoEstudio" => "REGULAR",
         "turno" => "NOCHE",
         "promedio" => 0
       }
     ]}
  end

  def get("lang-E001", "/Nota/NotasInglesXDetMatriculaId/555") do
    {:ok,
     [
       %{
         "detMatriculaId" => 555,
         "promedio" => 14.5,
         "nota1" => 15,
         "nota2" => "14",
         "nota3" => 0
       }
     ]}
  end

  def get(_token, _path), do: {:ok, []}
end
