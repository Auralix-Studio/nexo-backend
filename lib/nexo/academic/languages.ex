defmodule Nexo.Academic.Languages do
  @moduledoc """
  The student's Language Center (Idiomas) courses with their grades.

  Upstream quirks handled here: data and login live on different hosts,
  days come as `"LU-MA-MI"`, grades are fixed `nota1…nota6` columns where `0`
  means "no grade", and the grades of each course need their own request
  (made in parallel on the server).

  A student without a Language Center account has the session marker
  `"no_access"` (set at login): they get an empty list, and nothing is
  retried on every request.
  """
  alias Nexo.Infra.Cache
  alias Nexo.Schedule.Days
  alias Nexo.Upstream.{Languages, Normalize, Sessions}

  @no_access "no_access"
  @grade_columns ~w(nota1 nota2 nota3 nota4 nota5 nota6)
  @ttl :timer.hours(1)

  def no_access_marker, do: @no_access

  @doc """
  `{:ok, courses, status}` or `{:error, :reauth_required}`. Cached 1 h per
  user when the Language Center answered (or the student has no account).
  """
  def list(subject, student) do
    Cache.subject(subject, :languages, fn -> fetch(subject, student) end,
      ttl: @ttl,
      cache_if: &match?({:ok, _, status} when status in ["ok", "no_access"], &1)
    )
  end

  defp fetch(subject, student) do
    code = student["code"]

    result =
      Sessions.with_session(
        subject,
        :languages,
        fn
          @no_access ->
            {:ok, :no_access, @no_access}

          token ->
            with {:ok, rows} <-
                   Languages.get(token, "/Matricula/ListarMisAsignaturasMatriculadas/#{code}") do
              {:ok, courses(token, rows), token}
            end
        end,
        missing: :unavailable
      )

    case result do
      {:ok, :no_access} -> {:ok, [], "no_access"}
      {:ok, courses} -> {:ok, courses, "ok"}
      {:error, :reauth_required} -> {:error, :reauth_required}
      {:error, _} -> {:ok, [], "unavailable"}
    end
  end

  @doc """
  Schedule entries for the courses of the current month, for `/schedule`.
  Never fails: a Language Center problem only leaves its classes out.
  """
  def current_classes(subject, student) do
    case list(subject, student) do
      {:ok, courses, status} ->
        classes =
          for course <- courses, course.current, slot <- course.schedule do
            %{
              id: "lang-#{course.id}-#{slot.weekday}-#{slot.start}",
              course: %{code: nil, name: course.course, nrc: nil},
              section: course.section,
              kind: "language",
              weekday: slot.weekday,
              day: Days.name(slot.weekday),
              start: slot.start,
              end: slot.end,
              duration_minutes: slot.duration_minutes,
              room: %{
                campus: if(course.modality == "virtual", do: "Virtual"),
                building: if(course.modality != "virtual", do: "Centro de Idiomas"),
                name: course.room,
                capacity: nil
              },
              teacher: "Centro de Idiomas",
              modality: course.modality,
              source: "languages"
            }
          end

        {status, classes}

      {:error, :reauth_required} ->
        {"reauth_required", []}
    end
  end

  defp courses(token, rows) do
    rows = Enum.filter(rows, &is_map/1)

    grades =
      rows
      |> Task.async_stream(
        fn row ->
          id = Normalize.int(row["detMatriculaId"])

          case id && Languages.get(token, "/Nota/NotasInglesXDetMatriculaId/#{id}") do
            {:ok, grade_rows} ->
              {id, Enum.find(grade_rows, &(Normalize.int(&1["detMatriculaId"]) == id))}

            _ ->
              {id, nil}
          end
        end,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, pair} -> [pair]
        _ -> []
      end)
      |> Map.new()

    # The current month is Lima's: UTC is already next month on the last evening.
    today = Normalize.lima_today()
    Enum.map(rows, &course(&1, Map.get(grades, Normalize.int(&1["detMatriculaId"])), today))
  end

  @doc false
  def course(row, grade_row, today) do
    year = Normalize.int(row["anio"])
    month = Normalize.int(row["mes"])
    start = Days.hhmm(row["horaInicio"])
    finish = Days.hhmm(row["horaFin"])

    schedule =
      for weekday <- Days.parse_tokens(row["dias"]), start && finish do
        %{
          weekday: weekday,
          start: start,
          end: finish,
          duration_minutes: Days.minutes(finish) - Days.minutes(start)
        }
      end

    grade_row = grade_row || %{}
    items = Enum.map(@grade_columns, &Normalize.positive(grade_row[&1]))

    %{
      id: to_string(Normalize.int(row["detMatriculaId"]) || ""),
      language: Normalize.title(row["idiomaNombre"]),
      course: Normalize.title(row["asignatura"]),
      section: Normalize.text(row["seccion"]),
      modality: Normalize.modality(row["modalidad"]),
      period: %{year: year, month: month},
      current: year == today.year and month == today.month,
      shift: Normalize.title(row["turno"]),
      study_type: Normalize.title(row["tipoEstudio"]),
      room: Normalize.text(row["aulaNombre"]) || Normalize.text(row["aula"]),
      schedule: schedule,
      grades: %{
        items: items,
        average: Normalize.positive(grade_row["promedio"]) || Normalize.positive(row["promedio"])
      }
    }
  end
end
