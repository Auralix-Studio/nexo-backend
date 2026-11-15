defmodule Nexo.Teaching.Attendance do
  @moduledoc """
  A section's attendance sheet and its writes.

  Upstream (`Docente/GetAsistencia`) returns one row per student with every
  mark (`detalle[]`: `asistencia_id`, `fecha_asistencia`, `estado_asist_id`,
  `tipo_unidad_id`). Here a session is identified by its timestamp, states are
  words, and the ids a write needs (`matricula_asignatura_id`, `cod_cursal`,
  `asistencia_id`) are looked up on the server. A new session takes SIGMA's
  clock (`Docente/GetHora`, Lima wall time, its offset ignored) and SIGMA's
  date format with unpadded time. Suspended students are always recorded as
  suspended. Units SIGMA hides on its attendance screen are filtered.
  """
  alias Nexo.Infra.Cache
  alias Nexo.Teaching.{Gradebook, Sections, Upstream}
  alias Nexo.Upstream.Normalize

  @read_ttl :timer.minutes(3)
  @hidden_units [212, 214, 215, 115, 116]
  @risk_percent 70
  @states %{0 => "none", 1 => "present", 2 => "absent", 3 => "justified", 4 => "suspended"}
  @codes %{"none" => 0, "present" => 1, "absent" => 2, "justified" => 3, "suspended" => 4}

  @doc "Writable states."
  def writable_states, do: ~w(present absent justified)

  # --- Sheet ----------------------------------------------------------------------------

  @doc """
  `{:ok, sheet, meta}` or an error. Marks and units are cached
  #{div(@read_ttl, 60_000)} min per teacher and section (dropped by the
  teacher's writes); SIGMA's clock is read every time.
  """
  def sheet(subject, section_id) do
    with {:ok, section} <- Sections.resolve(subject, section_id),
         {:ok, {units, rows, _complete?}} <-
           Cache.subject(
             subject,
             {:attendance, section.id},
             fn -> fetch_sheet(subject, section) end,
             ttl: @read_ttl,
             cache_if: &match?({:ok, {_, _, true}}, &1)
           ) do
      time = server_time(&Upstream.get(subject, &1, &2))
      Upstream.audit(subject, :section_attendance_read, %{section: section.id})

      {:ok, build(section.id, units, time, rows), %{source: "sigma"}}
    end
  end

  defp fetch_sheet(subject, section) do
    Upstream.session(subject, fn get, _post ->
      with {:ok, rows} <- get.("/Docente/GetAsistencia", sheet_query(section)) do
        case get.("/Asignatura/getTipoUnidadesV2", units_query(section)) do
          {:ok, units} -> {:ok, {units(units), Upstream.maps(rows), true}}
          _ -> {:ok, {[], Upstream.maps(rows), false}}
        end
      end
    end)
  end

  @doc false
  def build(section_id, units, time, rows) do
    students =
      for row <- rows, code = Normalize.text(row["codigo"]), do: student(code, row)

    sessions =
      rows
      |> Enum.flat_map(&marks/1)
      |> Enum.group_by(& &1.session)
      |> Enum.map(fn {id, marks} ->
        count = fn state -> Enum.count(marks, &(&1.state == state)) end

        %{
          id: id,
          taken_at: id <> "-05:00",
          unit_id: marks |> hd() |> Map.get(:unit_id),
          present: count.("present"),
          absent: count.("absent"),
          justified: count.("justified")
        }
      end)
      |> Enum.sort_by(& &1.id)

    %{
      section_id: section_id,
      units: units,
      server_time: time,
      sessions: sessions,
      students: Enum.map(students, &Map.drop(&1, [:upstream]))
    }
  end

  defp student(code, row) do
    percent = Normalize.number(row["asistencia"])

    %{
      code: code,
      name: Normalize.title(row["nombreCompleto"] || row["nombre_completo"]),
      percent: percent,
      at_risk: is_number(percent) and percent <= @risk_percent,
      suspended: suspended?(row),
      marks: row |> marks() |> Enum.map(&Map.take(&1, [:session, :state]))
    }
  end

  defp suspended?(row), do: Gradebook.suspended?(row["observacion"])

  defp marks(row) do
    for m <- Upstream.maps(row["detalle"]),
        session = session_id(m["fecha_asistencia"] || m["fecha"]),
        session != nil do
      %{
        session: session,
        state: Map.get(@states, Normalize.int(m["estado_asist_id"] || m["estado"]), "none"),
        unit_id: Normalize.int(m["tipo_unidad_id"]),
        upstream_id: Normalize.int(m["asistencia_id"])
      }
    end
    |> Enum.sort_by(& &1.session)
  end

  @doc "`\"2026-10-29 9:5:0\"` → `\"2026-10-29T09:05:00\"`; `nil` if unreadable."
  def session_id(value) do
    case Regex.run(
           ~r/^(\d{4})-(\d{1,2})-(\d{1,2})[T ](\d{1,2}):(\d{1,2}):(\d{1,2})/,
           String.trim(to_string(value || ""))
         ) do
      [_, y, mo, d, h, mi, s] ->
        two = &String.pad_leading(&1, 2, "0")
        "#{y}-#{two.(mo)}-#{two.(d)}T#{two.(h)}:#{two.(mi)}:#{two.(s)}"

      _ ->
        nil
    end
  end

  defp units(rows) do
    for row <- Upstream.maps(rows),
        id = Normalize.int(row["tipo_unidad_id"] || row["tipoUnidadId"]),
        is_integer(id) and id != 0 and id not in @hidden_units,
        do: %{
          unit_id: id,
          name: Normalize.title(row["descripcion"] || row["nombre"]),
          open: Normalize.bool(row["habilitado"])
        }
  end

  defp server_time(get) do
    case get.("/Docente/GetHora", %{}) do
      {:ok, raw} -> raw |> session_id() |> then(&(&1 && &1 <> "-05:00"))
      _ -> nil
    end
  end

  defp sheet_query(section) do
    %{
      "plan" => to_string(section.upstream.plan),
      "codSaltem" => to_string(section.upstream.attendance_ids || section.upstream.cle_auto),
      "asignID" => to_string(section.upstream.nrc)
    }
  end

  defp units_query(section) do
    first_id =
      (section.upstream.attendance_ids || section.upstream.cle_auto || "")
      |> String.split(",")
      |> hd()
      |> String.trim()

    %{
      "tipoCalif" => "#{section.upstream.grading_type}",
      "cursal" => first_id,
      "asi_id" => to_string(section.upstream.nrc),
      "cle_auto" => "0"
    }
  end

  # --- Writes ---------------------------------------------------------------------------

  @doc "New session with SIGMA's clock: `{:ok, %{session, saved, failed}, meta}`."
  def take(subject, section_id, %{unit_id: unit_id, marks: marks}) do
    with {:ok, section} <- Sections.resolve(subject, section_id),
         {:ok, result} <-
           Sections.written(subject, section, fn ->
             take_marks(subject, section, unit_id, marks)
           end) do
      audit(subject, :section_attendance_taken, section, %{unit: unit_id, saved: result.saved})
      {:ok, result, %{source: "sigma"}}
    end
  end

  defp take_marks(subject, section, unit_id, marks) do
    Upstream.session(subject, fn get, post ->
      with {:ok, rows} <- get.("/Docente/GetAsistencia", sheet_query(section)),
           {:ok, units} <- get.("/Asignatura/getTipoUnidadesV2", units_query(section)),
           :ok <- known_unit(units(units), unit_id),
           {:ok, now} <- clock(get) do
        by_code = by_code(rows)

        {failed, ok} =
          Enum.split_with(
            Enum.map(marks, &take_mark(&1, by_code, unit_id)),
            &match?({:failed, _}, &1)
          )

        body = %{
          "fecha_asistencia" => upstream_time(now),
          "asistencia" => for({:ok, row} <- ok, do: row)
        }

        saved =
          if ok == [],
            do: {:ok, 0},
            else:
              post_result(
                post.("/Docente/InsertaRegistroAsistencia", %{}, body),
                length(ok)
              )

        with {:ok, saved} <- saved do
          {:ok,
           %{
             session: session_id(upstream_time(now)),
             saved: saved,
             failed: for({:failed, f} <- failed, do: f)
           }}
        end
      end
    end)
  end

  @doc "Corrects marks of an existing session: `{:ok, %{saved, failed}, meta}`."
  def correct(subject, section_id, session, %{marks: marks}) do
    with {:ok, section} <- Sections.resolve(subject, section_id),
         {:ok, result} <-
           Sections.written(subject, section, fn ->
             correct_marks(subject, section, session, marks)
           end) do
      audit(subject, :section_attendance_corrected, section, %{
        session: session,
        saved: result.saved
      })

      {:ok, result, %{source: "sigma"}}
    end
  end

  defp correct_marks(subject, section, session, marks) do
    Upstream.session(subject, fn get, post ->
      with {:ok, rows} <- get.("/Docente/GetAsistencia", sheet_query(section)) do
        by_code = by_code(rows)

        {failed, ok} =
          marks
          |> Enum.map(&correct_mark(&1, by_code, session))
          |> Enum.split_with(&match?({:failed, _}, &1))

        saved =
          if ok == [],
            do: {:ok, 0},
            else:
              post_result(
                post.("/Docente/ActualizarRegistroAsistencia", %{}, %{
                  "asistencia" => for({:ok, row} <- ok, do: row)
                }),
                length(ok)
              )

        with {:ok, saved} <- saved do
          {:ok, %{saved: saved, failed: for({:failed, f} <- failed, do: f)}}
        end
      end
    end)
  end

  defp by_code(rows) do
    for row <- Upstream.maps(rows),
        code = Normalize.text(row["codigo"]),
        into: %{},
        do: {code, row}
  end

  defp known_unit(units, unit_id) do
    if Enum.any?(units, &(&1.unit_id == unit_id)), do: :ok, else: {:error, :unknown_unit}
  end

  defp take_mark(mark, by_code, unit_id) do
    with {:ok, _code, row, state} <- check_mark(mark, by_code) do
      {:ok,
       %{
         "matricula_asignatura_id" => matricula(row),
         "estado_asist_id" => code_for(row, state),
         "cod_cursal" =>
           row["cod_cursal"] |> to_string() |> String.split(",") |> hd() |> String.trim(),
         "tipo_unidad_id" => unit_id
       }}
    end
  end

  defp correct_mark(mark, by_code, session) do
    with {:ok, code, row, state} <- check_mark(mark, by_code) do
      case Enum.find(marks(row), &(&1.session == session)) do
        nil ->
          {:failed, %{student: code, reason: "no_mark"}}

        existing ->
          {:ok,
           %{
             "asistencia_id" => existing.upstream_id,
             "matricula_asignatura_id" => matricula(row),
             "estado_asist_id" => code_for(row, state)
           }}
      end
    end
  end

  defp check_mark(mark, by_code) do
    code = Normalize.text(mark["student"])
    state = mark["state"]

    cond do
      code == nil or not Map.has_key?(by_code, code) ->
        {:failed, %{student: code, reason: "not_in_section"}}

      state not in writable_states() ->
        {:failed, %{student: code, reason: "invalid_state"}}

      true ->
        {:ok, code, by_code[code], state}
    end
  end

  defp code_for(row, state), do: if(suspended?(row), do: @codes["suspended"], else: @codes[state])

  defp matricula(row),
    do: to_string(row["matricula_asignatura_id"] || row["matriculaAsignaturaId"])

  defp post_result({:ok, %{success: true}}, n), do: {:ok, n}
  defp post_result({:ok, %{success: false}}, _), do: {:error, :rejected}
  defp post_result({:error, :session_expired}, _), do: {:error, :session_expired}
  defp post_result({:error, _}, _), do: {:error, :unavailable}

  # SIGMA's clock as wall time; the device's clock is never used.
  defp clock(get) do
    case get.("/Docente/GetHora", %{}) do
      {:ok, raw} ->
        case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/, to_string(raw)) do
          [_ | parts] -> {:ok, Enum.map(parts, &String.to_integer/1)}
          _ -> {:error, :unavailable}
        end

      error ->
        error
    end
  end

  # SIGMA's own format: padded date, unpadded time ("2026-10-29 9:5:0").
  defp upstream_time([y, mo, d, h, mi, s]) do
    two = &String.pad_leading(to_string(&1), 2, "0")
    "#{y}-#{two.(mo)}-#{two.(d)} #{h}:#{mi}:#{s}"
  end

  defp audit(subject, action, section, detail),
    do: Upstream.audit(subject, action, Map.put(detail, :section, section.id))
end
