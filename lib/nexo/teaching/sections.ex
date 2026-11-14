defmodule Nexo.Teaching.Sections do
  @moduledoc """
  The teacher's sections, one per real section.

  SIGMA lists them twice (`Docente/GetAsignaturaDocente?modo=Notas` and
  `?modo=Asistencia`) with different ids, and sometimes repeats a section in
  one list. The app used to cross both lists itself; here they are merged
  once (same NRC, then section and career), deduplicated, and given one Nexo
  id (`sec_…`). The upstream ids each operation needs (`cleAuto`, the
  attendance ids, `plan`, `tipoCalif`, the NRC) stay in the backend: routes
  resolve a Nexo id back to them, and only within the teacher's own list, so
  a teacher can never reach someone else's section.
  """
  alias Nexo.Academic.Schedule
  alias Nexo.Infra.Cache
  alias Nexo.Teaching.Upstream
  alias Nexo.Upstream.Normalize

  @ttl :timer.minutes(5)

  @doc "Public sections of the teacher: `{:ok, [section]}` or an error."
  def list(subject) do
    with {:ok, sections} <- internal(subject) do
      {:ok, Enum.map(sections, &public/1)}
    end
  end

  @doc "The internal section (with upstream ids) for a Nexo id, scoped to the teacher."
  def resolve(subject, id) do
    with {:ok, sections} <- internal(subject) do
      case Enum.find(sections, &(&1.id == id)) do
        nil -> {:error, :unknown_section}
        section -> {:ok, section}
      end
    end
  end

  defp internal(%{type: :teacher, id: id} = subject) do
    Cache.fetch({:teacher_sections, id}, @ttl, fn ->
      Upstream.session(subject, fn get, _post ->
        with {:ok, grades} <- get.("/Docente/GetAsignaturaDocente", %{"modo" => "Notas"}) do
          attendance =
            case get.("/Docente/GetAsignaturaDocente", %{"modo" => "Asistencia"}) do
              {:ok, rows} -> Upstream.maps(rows)
              _ -> []
            end

          {:ok, merge(Upstream.maps(grades), attendance)}
        end
      end)
    end)
  end

  defp internal(_), do: {:error, :forbidden}

  @doc false
  def public(s) do
    s
    |> Map.drop([:upstream])
    |> Map.update!(:schedule, &Enum.map(&1, fn b -> public_block(b) end))
  end

  @doc "Drops the cached list (after a write, or to refresh)."
  def forget(%{id: id}), do: Cache.delete({:teacher_sections, id})

  @doc """
  Crosses the two lists and drops duplicates. Each grades row takes its best
  attendance row (same NRC; +2 same section, +1 same career); attendance rows
  left over are sections too.
  """
  def merge(grades, attendance) do
    indexed = Enum.with_index(attendance)

    {paired, used} =
      Enum.map_reduce(grades, MapSet.new(), fn row, used ->
        best =
          indexed
          |> Enum.reject(fn {_, i} -> MapSet.member?(used, i) end)
          |> Enum.filter(fn {a, _} -> norm(a["nrc"]) == norm(row["nrc"]) end)
          |> Enum.max_by(fn {a, _} -> score(row, a) end, fn -> nil end)

        case best do
          {a, i} -> {{row, a}, MapSet.put(used, i)}
          nil -> {{row, nil}, used}
        end
      end)

    leftovers = for {a, i} <- indexed, not MapSet.member?(used, i), do: {a, a}

    (paired ++ leftovers)
    |> Enum.map(fn {row, att} -> build(row, att) end)
    |> Enum.reject(&is_nil/1)
    |> dedupe()
    |> Enum.sort_by(&{&1.course.name, &1.section})
  end

  defp score(row, a) do
    if(norm(a["seccion"]) == norm(row["seccion"]), do: 2, else: 0) +
      if(String.starts_with?(norm(a["carrera"]), norm(row["carrera"])), do: 1, else: 0)
  end

  defp norm(v), do: v |> to_string() |> String.trim() |> String.upcase()

  defp build(row, att) do
    raw_name = to_string(row["asignatura"] || row["nombreAsignatura"] || "")
    nrc = Normalize.text(row["nrc"] || row["asignID"] || row["asi_id"])
    grades_id = if att == row, do: nil, else: Normalize.text(row["cleAuto"] || row["id"])
    attendance_ids = att && Normalize.text(att["id"])
    att = att || %{}
    pick = fn key -> Normalize.text(att[key]) || Normalize.text(row[key]) end
    career_raw = pick.("carrera")
    campus = pick.("sede")
    room = Schedule.room(campus, pick.("aula"))
    key = grades_id || "att:" <> to_string(attendance_ids)

    if nrc || grades_id do
      %{
        id: "sec_" <> hash(key),
        term: term(row["periodo"], raw_name),
        nrc: nrc,
        course: %{code: Normalize.text(row["codigo"]) || nrc, name: course_name(raw_name)},
        section: pick.("seccion"),
        career: career(career_raw),
        modality: Normalize.modality(pick.("modalidad") || modality_of(career_raw)),
        cycle: Normalize.int(pick.("ciclo")),
        elective: raw_name =~ ~r/\(\s*ELECTIV/i,
        enrolled: Normalize.int(row["matriculados"] || row["cantMatriculados"]),
        campus: room.campus || Normalize.campus(campus),
        room: %{
          building: room.building || Normalize.title(pick.("local")),
          name: room.name,
          capacity: room.capacity
        },
        schedule: blocks(att["horario"], attendance_ids),
        upstream: %{
          cle_auto: grades_id,
          attendance_ids: attendance_ids,
          plan: Normalize.text(row["plan"] || att["plan"]),
          nrc: nrc,
          # SIGMA uses 12 when a section reports 0.
          grading_type: grading_type(row["tipoCalif"] || row["tipoCalificacion"])
        }
      }
    end
  end

  defp grading_type(value) do
    case Normalize.int(value) do
      n when is_integer(n) and n > 0 -> n
      _ -> 12
    end
  end

  defp hash(key) do
    :crypto.hash(:sha256, "nexo-section:" <> key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # Duplicates (same upstream id, or same NRC + section + career) become one,
  # schedules combined.
  defp dedupe(sections) do
    sections
    |> Enum.reduce([], fn s, acc ->
      case Enum.split_with(acc, &same?(&1, s)) do
        {[], _} ->
          acc ++ [s]

        {[existing | _], rest} ->
          merged = %{
            existing
            | schedule:
                Enum.uniq_by(existing.schedule ++ s.schedule, &{&1.weekday, &1.start, &1.end}),
              upstream: %{
                existing.upstream
                | cle_auto: existing.upstream.cle_auto || s.upstream.cle_auto,
                  attendance_ids: existing.upstream.attendance_ids || s.upstream.attendance_ids
              }
          }

          _ = rest
          Enum.map(acc, fn s -> if s == existing, do: merged, else: s end)
      end
    end)
  end

  defp same?(a, b) do
    a.id == b.id or
      (a.nrc != nil and a.nrc == b.nrc and a.section == b.section and
         (a.career == nil or b.career == nil or a.career == b.career))
  end

  # "BASE DE DATOS I (2026-2)" → "Base de Datos I"
  defp course_name(raw) do
    raw
    |> String.replace(~r/\s*\([^)]*\)/, " ")
    |> Normalize.title()
  end

  defp term(periodo, raw_name) do
    text =
      Normalize.text(periodo) ||
        case Regex.run(~r/\((\d{4}\s*-\s*\d)\)/, raw_name) do
          [_, t] -> t
          _ -> nil
        end

    case text && Regex.run(~r/(\d{4})\s*-\s*(\d)/, text) do
      [_, y, n] -> "#{y}-#{n}"
      _ -> nil
    end
  end

  @modalities ~r/\s*-\s*(PRESENCIAL|DISTANCIA|SEMIPRESENCIAL|VIRTUAL)\s*$/i

  defp career(nil), do: nil
  defp career(raw), do: raw |> String.replace(@modalities, "") |> Normalize.title()

  defp modality_of(nil), do: nil

  defp modality_of(raw) do
    case Regex.run(@modalities, raw) do
      [_, m] -> m
      _ -> nil
    end
  end

  @days %{
    "LUNES" => 1,
    "MARTES" => 2,
    "MIERCOLES" => 3,
    "MIÉRCOLES" => 3,
    "JUEVES" => 4,
    "VIERNES" => 5,
    "SABADO" => 6,
    "SÁBADO" => 6,
    "DOMINGO" => 7
  }

  @doc """
  `"Jueves 11:30:00 13:00:00 P, Miércoles 10:45:00 11:30:00 T"` → blocks.
  SIGMA's schedule ids (`"419329, 419321"`) belong to the days in Sunday-first
  order; they are kept internally as each block's `cod_cursal`.
  """
  def blocks(nil, _ids), do: []

  def blocks(text, ids) do
    ids = (ids || "") |> String.split(",") |> Enum.map(&String.trim/1)

    parsed =
      for part <- String.split(text, ","),
          [day, start, finish | rest] <- [String.split(String.trim(part), ~r/\s+/)],
          weekday = @days[String.upcase(day)],
          weekday != nil,
          do: %{weekday: weekday, start: hm(start), end: hm(finish), kind: kind(List.first(rest))}

    order = fn wd -> if wd == 7, do: 0, else: wd end

    day_ids =
      parsed
      |> Enum.map(& &1.weekday)
      |> Enum.uniq()
      |> Enum.sort_by(order)
      |> Enum.with_index()
      |> Map.new(fn {wd, i} -> {wd, Enum.at(ids, i)} end)

    parsed
    |> Enum.map(&Map.put(&1, :cod_cursal, day_ids[&1.weekday]))
    |> Enum.sort_by(&{&1.weekday, &1.start})
  end

  defp hm(t) do
    case String.split(t, ":") do
      [h, m | _] -> String.pad_leading(h, 2, "0") <> ":" <> String.pad_leading(m, 2, "0")
      _ -> t
    end
  end

  defp kind(nil), do: "theory"

  defp kind(code) do
    case String.upcase(code) do
      "P" -> "practice"
      "L" -> "lab"
      _ -> "theory"
    end
  end

  @doc "Public block (without the upstream schedule id)."
  def public_block(b), do: Map.delete(b, :cod_cursal)
end
