defmodule Nexo.Academic.Schedule do
  @moduledoc """
  The student's weekly schedule for a term, in one clean shape.

  Sources, in order (as the app did): the Intranet's enrollment matrix, then
  SIGMA. Language Center classes of the current month are added on top.

  The Intranet matrix is the tricky one: each row is a time slot, columns 3–9
  are Monday–Sunday, and each cell packs 14 `_`-separated fields; when two
  courses share a cell, every field holds a comma-separated list. Fixes over
  the app's reading of it:

    * the colour field (`rgba(…)`) contains commas and is never split;
    * practice sessions held in a lab are `lab`, not `theory`;
    * SIGMA's teacher (`docente`) is read; the app read a missing key.
  """
  alias Nexo.Academic.{Languages, Terms}
  alias Nexo.Schedule.Days
  alias Nexo.Upstream.{Intranet, Normalize, Sessions}

  @doc "`{:ok, schedule, sources}` or `{:error, :reauth_required | :unknown_term}`."
  def get(subject, student, term_id \\ nil) do
    with {:ok, term} <- Terms.resolve(subject, term_id) do
      intranet = from_intranet(subject, term)

      {university, sigma} =
        case intranet do
          {:ok, [_ | _] = classes} -> {classes, :skipped}
          _ -> sigma_fallback(subject)
        end

      languages = Languages.current_classes(subject, student)

      if match?({:error, :reauth_required}, intranet) and
           match?({:error, :reauth_required}, sigma) do
        {:error, :reauth_required}
      else
        classes =
          (university ++ elem(languages, 1))
          |> Enum.sort_by(&{&1.weekday, &1.start, &1.course.name})

        {:ok, %{term: %{id: term.id, label: term.label}, classes: classes},
         %{
           intranet: Sessions.status(intranet),
           sigma: if(sigma == :skipped, do: "not_needed", else: Sessions.status(sigma)),
           languages: elem(languages, 0)
         }}
      end
    end
  end

  defp sigma_fallback(subject) do
    case from_sigma(subject) do
      {:ok, classes} = ok -> {classes, ok}
      error -> {[], error}
    end
  end

  # --- Intranet ---------------------------------------------------------------------

  defp from_intranet(subject, term) do
    form = %{"periodo" => "#{term.year}-#{term.number}"}

    Sessions.with_session(subject, :intranet, fn cookies ->
      with {:ok, matrix, cookies} <-
             Intranet.post(
               cookies,
               "verhorariomatriz-matriculados3EstudianteEstudiante",
               form,
               "reportesDelEstudiante"
             ) do
        details =
          case Intranet.post(
                 cookies,
                 "verhorarioseleccion-detalleEstudiante",
                 form,
                 "reportesDelEstudiante"
               ) do
            {:ok, rows, _} -> details(rows)
            _ -> %{teachers: %{}, labs: %{}}
          end

        {:ok, parse_matrix(matrix, details), cookies}
      end
    end)
  end

  @doc false
  def details(rows) do
    Enum.reduce(rows, %{teachers: %{}, labs: %{}}, fn
      [name | _] = row, acc when is_binary(name) ->
        case Normalize.text(name) do
          nil ->
            acc

          course ->
            teacher = Normalize.text(Enum.at(row, 9))
            lab = Enum.find(row, &(is_binary(&1) and &1 =~ ~r/LAB_|LABORATORIO/i))

            acc
            |> then(&if(teacher, do: put_in(&1, [:teachers, course], teacher), else: &1))
            |> then(&if(lab, do: put_in(&1, [:labs, course], String.trim(lab)), else: &1))
        end

      _row, acc ->
        acc
    end)
  end

  @doc false
  def parse_matrix(rows, details) do
    {classes, _seen} =
      for row <- rows, is_list(row), day <- 3..9, reduce: {[], MapSet.new()} do
        acc ->
          case Enum.at(row, day) do
            cell when is_binary(cell) -> parse_cell(cell, day - 2, details, acc)
            _ -> acc
          end
      end

    Enum.reverse(classes)
  end

  defp parse_cell(cell, weekday, details, {classes, seen} = acc) do
    fields = cell |> String.trim() |> String.split("_")

    if length(fields) < 13 do
      acc
    else
      ids = fields |> Enum.at(0) |> String.split(",")
      count = length(ids)

      Enum.reduce(0..(count - 1), {classes, seen}, fn i, {classes, seen} ->
        at = fn index -> field(fields, index, i, count) end
        id = at.(0)

        if is_nil(id) or MapSet.member?(seen, id) do
          {classes, seen}
        else
          course = at.(2)
          practice? = (at.(13) || "") |> String.downcase() |> String.starts_with?("p")
          lab_location = practice? && details.labs[course]
          location = lab_location || at.(12)

          kind =
            cond do
              lab_location -> "lab"
              (practice? and location) && location =~ ~r/LAB/i -> "lab"
              practice? -> "practice"
              true -> "theory"
            end

          class =
            build(%{
              source_id: "intranet-#{id}",
              code: at.(1),
              nrc: nil,
              name: course,
              section: at.(10),
              kind: kind,
              weekday: weekday,
              start: at.(8),
              finish: at.(9),
              campus: at.(11),
              location: location,
              teacher: details.teachers[course],
              modality: nil
            })

          {if(class, do: [class | classes], else: classes), MapSet.put(seen, id)}
        end
      end)
    end
  end

  # Field 6 is a colour like `rgba(1, 2, 3, 0.5)`: never split. Other fields
  # are split per course only when the cell holds more than one course.
  defp field(fields, index, i, count) do
    raw = Enum.at(fields, index)

    value =
      cond do
        is_nil(raw) -> nil
        count == 1 or index == 6 -> raw
        true -> raw |> String.split(",") |> then(&(Enum.at(&1, i) || List.last(&1)))
      end

    Normalize.text(value)
  end

  # --- SIGMA --------------------------------------------------------------------------

  defp from_sigma(subject) do
    with {:ok, data} <-
           Sessions.sigma_fetch(subject, "/Intranet/ListarHorariosEstudianteIntranet/*/*"),
         do: {:ok, for(row <- List.wrap(data), is_map(row), class = sigma_class(row), do: class)}
  end

  defp sigma_class(row) do
    kind =
      case row["idTipo"] |> Normalize.text() |> then(&(&1 && String.upcase(&1))) do
        "P" -> "practice"
        "L" -> "lab"
        _ -> "theory"
      end

    location =
      [row["local"], row["aula"]] |> Enum.map(&Normalize.text/1) |> Enum.reject(&is_nil/1)

    build(%{
      source_id: "sigma-#{row["id"]}",
      code: Normalize.text(row["id"]),
      nrc: Normalize.text(row["nrc"]),
      name: Normalize.text(row["asignatura"]),
      section: Normalize.text(row["seccion"]),
      kind: kind,
      weekday: Normalize.int(row["idDia"]),
      start: Normalize.text(row["horaInicio"]),
      finish: Normalize.text(row["horaFin"]),
      campus: Normalize.text(row["sede"]),
      location: Enum.join(location, " - "),
      teacher: Normalize.text(row["docente"]),
      modality: Normalize.modality(row["modalidad"])
    })
  end

  # --- Shared shape -------------------------------------------------------------------

  @doc false
  def build(%{weekday: weekday, start: start, finish: finish, name: name} = attrs) do
    with true <- is_integer(weekday) and weekday in 1..7,
         start when is_binary(start) <- Days.hhmm(start),
         finish when is_binary(finish) <- Days.hhmm(finish),
         true <- start < finish,
         true <- is_binary(name) do
      %{
        id: class_id(attrs.source_id, weekday, start),
        course: %{code: attrs.code, name: Normalize.title(name), nrc: attrs.nrc},
        section: attrs.section,
        kind: attrs.kind,
        weekday: weekday,
        day: Days.name(weekday),
        start: start,
        end: finish,
        duration_minutes: Days.minutes(finish) - Days.minutes(start),
        room: room(attrs.campus, attrs.location),
        teacher: Normalize.title(attrs.teacher),
        modality: attrs.modality,
        source: "university"
      }
    else
      _ -> nil
    end
  end

  @doc "Building, room and capacity from `\"PABELLON H - H 302 - AFORO: 40\"`."
  def room(campus, location) do
    parts =
      (location || "")
      |> String.split(~r/\s*-\s*/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {capacity, rest} =
      Enum.split_with(parts, &(&1 =~ ~r/^AFORO\s*:\s*\d+$/i))

    capacity =
      case capacity do
        [aforo | _] -> aforo |> String.replace(~r/\D/, "") |> Normalize.int()
        [] -> nil
      end

    {buildings, names} =
      Enum.split_with(rest, &(&1 =~ ~r/^(PABELL[OÓ]N|EDIFICIO|TORRE|LABORATORIO)\b/i))

    %{
      campus: Normalize.campus(campus),
      building:
        buildings
        |> List.first()
        |> then(&(&1 && String.replace(&1, ~r/^PABELLON/i, "PABELLÓN")))
        |> Normalize.title(),
      name: names |> List.first() |> Normalize.text(),
      capacity: if(capacity && capacity > 0, do: capacity)
    }
  end

  defp class_id(source_id, weekday, start) do
    :crypto.hash(:sha256, "#{source_id}|#{weekday}|#{start}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
