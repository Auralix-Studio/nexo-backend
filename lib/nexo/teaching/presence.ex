defmodule Nexo.Teaching.Presence do
  @moduledoc """
  The teacher's own attendance: today's classes to check in virtually, the
  punch history and the per-class compliance report.

  Upstream: `Docente/getAsistenciaDocente` (times `00:00:00` mean "no mark"),
  `Docente/InsertaRegistroAsistenciaDocente?codigo=` (SIGMA decides check-in
  or check-out and answers `"S - …"`, `"I - …"` or `"E - …"`),
  `Docente/getHistorialMarcacion` and `Docente/getAsistenciaDiaria` (paged,
  `fecha` as `MM/dd/yyyy`, statuses `1` marked, `X` missing, `0` pending; the
  pages are walked and deduplicated here).
  """
  alias Nexo.Security.Audit
  alias Nexo.Teaching.Upstream
  alias Nexo.Upstream.Normalize

  @max_pages 4

  # --- Virtual classes ------------------------------------------------------------------

  @doc "`{:ok, classes, meta}`."
  def virtual_classes(subject) do
    with {:ok, rows} <- Upstream.get(subject, "/Docente/getAsistenciaDocente") do
      {:ok, rows |> Upstream.maps() |> Enum.map(&virtual_class/1) |> Enum.reject(&is_nil/1),
       %{source: "sigma"}}
    end
  end

  @doc false
  def virtual_class(row) do
    id = Normalize.text(row["codigo"])

    if id do
      check_in = mark(row["marc_entrada"])
      check_out = mark(row["marc_salida"])

      %{
        id: id,
        course: course_name(row["asignatura"]),
        section: Normalize.text(row["seccion"]),
        career: Normalize.title(row["car_Id"]),
        start: hm(row["hora_ini"]),
        end: hm(row["hora_fin"]),
        tolerance: %{
          before_minutes: Normalize.int(row["tol_ini"]) || 0,
          after_minutes: Normalize.int(row["tol_fin"]) || 0
        },
        checked_in_at: check_in,
        checked_out_at: check_out,
        can_check_in: check_in == nil,
        can_check_out: check_in != nil and check_out == nil
      }
    end
  end

  defp mark(value) do
    case Normalize.text(value) do
      nil -> nil
      "00:00:00" -> nil
      "00:00" -> nil
      t -> hm(t)
    end
  end

  @doc "Checks in or out of one of today's classes: `{:ok, %{result, message}, meta}`."
  def punch(subject, class_id) do
    Upstream.session(subject, fn get, post ->
      with {:ok, rows} <- get.("/Docente/getAsistenciaDocente", %{}),
           true <-
             Enum.any?(Upstream.maps(rows), &(Normalize.text(&1["codigo"]) == class_id)) ||
               {:error, :unknown_class} do
        case post.("/Docente/InsertaRegistroAsistenciaDocente", %{"codigo" => class_id}, nil) do
          {:ok, %{success: true, message: message}} ->
            {:ok, sigma_message(message)}

          {:ok, %{success: false, message: message}} ->
            {:ok, %{sigma_message(message) | result: "error"}}

          error ->
            error
        end
      end
    end)
    |> case do
      {:ok, result} ->
        Audit.log(:teacher_virtual_punch, %{
          actor_type: "teacher",
          actor_id: subject.id,
          detail: %{class: class_id, result: result.result}
        })

        {:ok, result, %{source: "sigma"}}

      error ->
        error
    end
  end

  @doc "`\"S - Entrada registrada\"` → `%{result: \"success\", message: \"Entrada registrada\"}`."
  def sigma_message(message) do
    text = String.trim(to_string(message || ""))

    case Regex.run(~r/^([SIE])\s*-\s*(.*)$/s, text) do
      [_, kind, rest] ->
        %{result: %{"S" => "success", "I" => "info", "E" => "error"}[kind], message: rest}

      _ ->
        %{result: "success", message: if(text == "", do: nil, else: text)}
    end
  end

  # --- Punch history --------------------------------------------------------------------

  @doc "`{:ok, punches, meta}` between two ISO dates."
  def punches(subject, from, to) do
    query = %{"fechaInicio" => from, "fechaFin" => to, "pagina" => "1"}

    with {:ok, rows} <- Upstream.get(subject, "/Docente/getHistorialMarcacion", query) do
      {:ok, rows |> Upstream.maps() |> Enum.map(&punch_row/1) |> Enum.reject(&is_nil/1),
       %{source: "sigma"}}
    end
  end

  @doc false
  def punch_row(row) do
    with date when is_binary(date) <- date(row["fecha"]) do
      location = Normalize.text(row["ubcacionMarcador"] || row["ubicacionMarcador"])

      %{
        date: date,
        time: hm(row["hora"]),
        weekday: Normalize.int(row["idDia"]) || weekday(date),
        mode: Normalize.text(row["modo"]),
        location: location,
        virtual: String.starts_with?(String.upcase(location || ""), "VIRTUAL")
      }
    else
      _ -> nil
    end
  end

  # --- Compliance -----------------------------------------------------------------------

  @doc "`{:ok, classes, meta}` between two ISO dates, pages walked and deduplicated."
  def compliance(subject, from, to) do
    Upstream.session(subject, fn get, _post -> walk(get, from, to, 1, MapSet.new(), []) end)
    |> case do
      {:ok, list} -> {:ok, Enum.sort_by(list, &{&1.date, &1.start}, :desc), %{source: "sigma"}}
      error -> error
    end
  end

  defp walk(_get, _from, _to, page, _seen, acc) when page > @max_pages, do: {:ok, acc}

  defp walk(get, from, to, page, seen, acc) do
    query = %{"fechaInicio" => from, "fechaFin" => to, "pagina" => "#{page}"}

    with {:ok, rows} <- get.("/Docente/getAsistenciaDiaria", query) do
      new =
        rows
        |> Upstream.maps()
        |> Enum.map(&compliance_row/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&MapSet.member?(seen, key(&1)))
        |> Enum.uniq_by(&key/1)

      # An empty or repeated page means there are no more (SIGMA may ignore `pagina`).
      if new == [],
        do: {:ok, acc},
        else: walk(get, from, to, page + 1, Enum.into(Enum.map(new, &key/1), seen), acc ++ new)
    end
  end

  defp key(c), do: {c.date, c.start, c.course, c.section}

  @doc false
  def compliance_row(row) do
    with date when is_binary(date) <- date(row["fecha"]) do
      %{
        date: date,
        weekday: Normalize.int(row["idDia"]) || weekday(date),
        course: course_name(row["asignatura"]),
        section: Normalize.text(row["seccion"]),
        start: hm(row["horaInicio"]),
        end: hm(row["horaFin"]),
        modality: Normalize.modality(row["modalidad"]),
        check_in: status(row["statusInicio"]),
        check_out: status(row["statusFin"])
      }
    else
      _ -> nil
    end
  end

  defp status(value) do
    case value |> to_string() |> String.trim() |> String.upcase() do
      "1" -> "marked"
      "X" -> "missing"
      v when v in ["0", ""] -> "pending"
      _ -> "unknown"
    end
  end

  # --- Shared ---------------------------------------------------------------------------

  # ISO (`2026-10-07T00:00:00`) or SIGMA's `MM/dd/yyyy HH:mm:ss`.
  defp date(value) do
    text = String.trim(to_string(value || ""))

    cond do
      match = Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})/, text) ->
        [_, y, m, d] = match
        "#{y}-#{m}-#{d}"

      match = Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})/, text) ->
        [_, m, d, y] = match
        two = &String.pad_leading(&1, 2, "0")
        "#{y}-#{two.(m)}-#{two.(d)}"

      true ->
        nil
    end
  end

  defp weekday(iso) do
    case Date.from_iso8601(iso) do
      {:ok, d} -> Date.day_of_week(d)
      _ -> nil
    end
  end

  defp hm(value) do
    case Regex.run(~r/(\d{1,2}):(\d{2})/, to_string(value || "")) do
      [_, h, m] -> String.pad_leading(h, 2, "0") <> ":" <> m
      _ -> nil
    end
  end

  defp course_name(raw) do
    raw |> to_string() |> String.replace(~r/\s*\([^)]*\)/, " ") |> Normalize.title()
  end
end
