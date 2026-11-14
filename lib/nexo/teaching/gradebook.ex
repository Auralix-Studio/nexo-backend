defmodule Nexo.Teaching.Gradebook do
  @moduledoc """
  A section's grades: the roster with every student's units, the grading
  catalog, and writes.

  Upstream (`Docente/NotasEstudianteResumenV1`) nests grades as
  `unidades[].grupos[].notas[]`, where a grade's column is only its position
  and each grade carries an `idNota` needed to change it. Writes are two
  endpoints (`InsertarNotas` for a new column, `UpdateNota` with `nota_id`).
  Here a write says unit, type, column and value per student code; the
  backend picks insert or update, validates the range, skips unchanged
  values and reports per student. `tipoCalif` 0 means 12 upstream.
  """
  alias Nexo.Security.Audit
  alias Nexo.Teaching.{Sections, Upstream}
  alias Nexo.Upstream.Normalize

  @risk_percent 70
  @type_order %{"EV" => 1, "DE" => 2, "PR" => 3}

  # --- Roster ------------------------------------------------------------------------

  @doc "`{:ok, roster, meta}` or an error."
  def roster(subject, section_id) do
    with {:ok, section} <- Sections.resolve(subject, section_id),
         {:ok, rows} <-
           Upstream.get(subject, "/Docente/NotasEstudianteResumenV1", summary_query(section)) do
      audit(subject, :section_roster_read, section)

      {:ok,
       %{
         section_id: section.id,
         students: rows |> Upstream.maps() |> Enum.map(&student/1) |> Enum.reject(&is_nil/1)
       }, %{source: "sigma"}}
    end
  end

  defp summary_query(section) do
    %{
      "tipoCalificacion" => "#{section.upstream.grading_type}",
      "cleAuto" => to_string(section.upstream.cle_auto || section.upstream.attendance_ids)
    }
  end

  @doc false
  def student(row) do
    code = Normalize.text(row["codigo"] || row["est_Id"])

    if code do
      percent = Normalize.number(row["asistencia"])
      units = row["unidades"] |> Upstream.maps() |> Enum.map(&unit/1)

      graded? =
        Enum.any?(units, fn u ->
          Enum.any?(u.evaluations, &Enum.any?(&1.grades, fn g -> g != nil end))
        end)

      %{
        code: code,
        name: Normalize.title(row["nombreCompleto"] || row["nombre_completo"]),
        photo_url: Normalize.photo_url(code),
        attendance_percent: percent,
        at_risk: is_number(percent) and percent <= @risk_percent,
        suspended: suspended?(row["observacion"]),
        final_grade:
          if(graded?, do: Normalize.number(row["notaFinal"] || row["nota"] || row["promedio"])),
        units: units
      }
    end
  end

  @doc false
  def suspended?(observation) do
    (Normalize.text(observation) || "") |> String.downcase() |> String.starts_with?("suspensi")
  end

  defp unit(u) do
    evaluations =
      u["grupos"]
      |> Upstream.maps()
      |> Enum.map(fn g ->
        abbr = Normalize.text(g["tipoNotaAbr"])

        %{
          type_id: Normalize.int(g["idTipoNota"]),
          type: type_word(abbr),
          abbr: abbr,
          weight_percent: Normalize.number(g["peso"]),
          grades: g["notas"] |> Upstream.maps() |> Enum.map(&Normalize.number(&1["valor"]))
        }
      end)
      |> Enum.sort_by(&Map.get(@type_order, &1.abbr, 99))

    %{
      unit_id: Normalize.int(u["unidadId"]),
      name: Normalize.title(u["nombre"]),
      weight_percent: Normalize.number(u["porcentaje"]),
      average: Normalize.number(u["promedioUnidad"]),
      evaluations: evaluations
    }
  end

  defp type_word("EV"), do: "knowledge"
  defp type_word("DE"), do: "performance"
  defp type_word("PR"), do: "product"
  defp type_word(_), do: "other"

  # --- Grading catalog ---------------------------------------------------------------

  @doc "Units of the section with their grade types: `{:ok, units, meta}`."
  def grade_units(subject, section_id) do
    with {:ok, section} <- Sections.resolve(subject, section_id),
         {:ok, units} <-
           Upstream.session(subject, fn get, _post -> catalog(get, section) end) do
      {:ok, units, %{source: "sigma"}}
    end
  end

  defp catalog(get, section) do
    with {:ok, rows} <- get.("/Asignatura/getTipoUnidadesV2", units_query(section)) do
      units =
        for row <- Upstream.maps(rows),
            id = Normalize.int(row["tipo_unidad_id"] || row["tipoUnidadId"]),
            is_integer(id) and id != 0 do
          types =
            case get.("/Asignatura/getTipoNota", %{"tipoUnidad" => "#{id}"}) do
              {:ok, types} ->
                types |> Upstream.maps() |> Enum.map(&grade_type/1) |> Enum.reject(&is_nil/1)

              _ ->
                []
            end

          %{
            unit_id: id,
            name: Normalize.title(row["descripcion"] || row["nombre"]),
            open: Normalize.bool(row["habilitado"]),
            types: types
          }
        end

      {:ok, units}
    end
  end

  defp units_query(section) do
    %{
      "tipoCalif" => "#{section.upstream.grading_type}",
      "cursal" => "0",
      "asi_id" => to_string(section.upstream.nrc),
      "cle_auto" => to_string(section.upstream.cle_auto)
    }
  end

  defp grade_type(row) do
    id = Normalize.int(row["tipo_nota_id"])

    if is_integer(id) and id != 0 do
      %{
        type_id: id,
        abbr: Normalize.text(row["tipo_nota_abr"]),
        name: Normalize.title(row["tipo_nota_desc"]),
        max: scale_max(row["tipo_nota_escala"]),
        passing: Normalize.number(row["minimo_aprob"]) || 10.5,
        max_columns: Normalize.int(row["tipo_nota_cant_max"]) || 1,
        color: Normalize.text(row["tipo_nota_color"])
      }
    end
  end

  # "0 - 20    " → 20
  defp scale_max(value) do
    ~r/\d+(?:[.,]\d+)?/
    |> Regex.scan(to_string(value))
    |> List.flatten()
    |> List.last()
    |> case do
      nil -> 20
      n -> Normalize.number(String.replace(n, ",", "."))
    end
  end

  # --- Writes --------------------------------------------------------------------------

  @doc """
  Saves one grade column for several students. `params`: `unit_id`,
  `type_id`, optional `column` (default for every grade: the next free
  column), `grades: [%{"student", "value", "column"?}]`.
  """
  def write(subject, section_id, params) do
    with {:ok, section} <- Sections.resolve(subject, section_id) do
      result =
        Upstream.session(subject, fn get, post ->
          with {:ok, units} <- catalog(get, section),
               {:ok, unit} <- find_unit(units, params.unit_id),
               {:ok, type} <- find_type(unit, params.type_id),
               {:ok, rows} <- get.("/Docente/NotasEstudianteResumenV1", summary_query(section)) do
            {:ok, save(post, unit, type, params, Upstream.maps(rows))}
          end
        end)

      with {:ok, summary} <- result do
        audit(subject, :section_grades_written, section, %{
          unit: params.unit_id,
          type: params.type_id,
          saved: summary.saved
        })

        {:ok, summary, %{source: "sigma"}}
      end
    end
  end

  defp find_unit(units, id) do
    case Enum.find(units, &(&1.unit_id == id)) do
      nil -> {:error, :unknown_unit}
      unit -> {:ok, unit}
    end
  end

  defp find_type(unit, id) do
    case Enum.find(unit.types, &(&1.type_id == id)) do
      nil -> {:error, :unknown_grade_type}
      type -> {:ok, type}
    end
  end

  defp save(post, unit, type, params, roster) do
    by_code = Map.new(roster, &{Normalize.text(&1["codigo"]), &1})

    planned =
      Enum.map(params.grades, fn item ->
        plan(item, by_code, unit, type, params[:column])
      end)

    {failed, actions} = Enum.split_with(planned, &match?({:failed, _, _}, &1))
    inserts = for {:insert, code, row} <- actions, do: {code, row}
    updates = for {:update, code, row} <- actions, do: {code, row}
    unchanged = Enum.count(actions, &match?({:unchanged, _}, &1))

    {saved_ins, failed_ins} = send(post, "/Docente/InsertarNotas", inserts)
    {saved_upd, failed_upd} = send(post, "/Docente/UpdateNota", updates)

    %{
      saved: saved_ins + saved_upd,
      unchanged: unchanged,
      failed:
        Enum.map(failed, fn {:failed, code, reason} -> %{student: code, reason: reason} end) ++
          failed_ins ++ failed_upd
    }
  end

  defp plan(item, by_code, unit, type, default_column) do
    code = Normalize.text(item["student"])
    value = item["value"]
    column = Map.get(item, "column", default_column)

    cond do
      not unit.open ->
        {:failed, code, "unit_closed"}

      code == nil or not Map.has_key?(by_code, code) ->
        {:failed, code, "not_in_section"}

      not is_number(value) or value < 0 or value > type.max ->
        {:failed, code, "invalid_value"}

      not (is_nil(column) or (is_integer(column) and column >= 0)) ->
        {:failed, code, "invalid_column"}

      true ->
        place(code, by_code[code], unit, type, Float.round(value * 1.0, 2), column)
    end
  end

  defp place(code, row, unit, type, value, column) do
    cells = cells(row, unit.unit_id, type.type_id)
    column = column || length(cells)
    matricula = to_string(row["matricula_asignatura_id"] || row["matriculaAsignaturaId"])

    base = %{
      "matricula_asignatura_id" => matricula,
      "tipo_unidad_id" => unit.unit_id,
      "tipo_nota_id" => type.type_id,
      "nota" => value
    }

    cond do
      column >= type.max_columns ->
        {:failed, code, "invalid_column"}

      column < length(cells) ->
        cell = Enum.at(cells, column)

        if cell.value == value,
          do: {:unchanged, code},
          else: {:update, code, Map.put(base, "nota_id", cell.id)}

      column == length(cells) ->
        {:insert, code, base}

      true ->
        {:failed, code, "column_gap"}
    end
  end

  defp cells(row, unit_id, type_id) do
    row["unidades"]
    |> Upstream.maps()
    |> Enum.filter(&(Normalize.int(&1["unidadId"]) == unit_id))
    |> Enum.flat_map(&Upstream.maps(&1["grupos"]))
    |> Enum.filter(&(Normalize.int(&1["idTipoNota"]) == type_id))
    |> Enum.flat_map(&Upstream.maps(&1["notas"]))
    |> Enum.map(&%{id: Normalize.int(&1["idNota"]), value: Normalize.number(&1["valor"])})
  end

  defp send(_post, _path, []), do: {0, []}

  defp send(post, path, items) do
    case post.(path, %{}, %{"Notas" => Enum.map(items, &elem(&1, 1))}) do
      {:ok, %{success: true}} ->
        {length(items), []}

      {:ok, %{success: false}} ->
        {0, Enum.map(items, &%{student: elem(&1, 0), reason: "rejected"})}

      {:error, :session_expired} = error ->
        throw_expired(error)

      {:error, _} ->
        {0, Enum.map(items, &%{student: elem(&1, 0), reason: "upstream_unavailable"})}
    end
  end

  # A dead session mid-write must surface as reauth, not as per-student errors.
  defp throw_expired(_), do: raise(Nexo.Teaching.SessionExpired)

  defp audit(subject, action, section, detail \\ %{}) do
    Audit.log(action, %{
      actor_type: "teacher",
      actor_id: subject.id,
      detail: Map.merge(%{section: section.id}, detail)
    })
  end
end

defmodule Nexo.Teaching.SessionExpired do
  @moduledoc false
  defexception message: "SIGMA session expired during a write"
end
