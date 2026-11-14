defmodule Nexo.Academic.Profile do
  @moduledoc """
  The student profile, built from SIGMA (`MostrarInfoEstudiante`,
  `MostrarNotasResumen`) and the Intranet (`datosEstudianteMatriculado` and
  the enrollment certificate of the active term).

  Fixes over what the app did on its own:

    * approved credits come from SIGMA; the Intranet number the app used was
      really this term's **enrolled** credits (`credits.enrolled_this_term`);
    * campus codes (`HU`) become names, upper-case text becomes title case,
      cycles become integers whatever their padding;
    * a source that does not answer leaves `null` fields, never zeros.
  """
  alias Nexo.Academic.Terms
  alias Nexo.Sigma
  alias Nexo.Upstream.{Intranet, Normalize, Sessions}

  @doc "`{:ok, profile, sources}` or `{:error, :reauth_required}`."
  def get(subject, student) do
    {terms, term_sources} =
      case Terms.list(subject) do
        {:ok, terms, sources} -> {terms, sources}
        {:error, _} -> {[], %{}}
      end

    active = Terms.active(terms)

    [info, datos, certificate] =
      [
        fn -> sigma_info(subject) end,
        fn -> intranet_basic(subject) end,
        fn -> intranet_certificate(subject, active) end
      ]
      |> Task.async_stream(& &1.(), timeout: 35_000, on_timeout: :kill_task, ordered: true)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> {:error, :unavailable}
      end)

    summary = sigma_summary(subject, ok(info))

    if Enum.all?([info, datos, certificate], &match?({:error, :reauth_required}, &1)) do
      {:error, :reauth_required}
    else
      sources = %{
        sigma: worst([info, summary]),
        intranet: worst([datos, certificate]) |> fallback(term_sources[:intranet])
      }

      {:ok, build(student, ok(info), ok(summary), ok(datos), ok(certificate), active), sources}
    end
  end

  # --- Upstream reads -----------------------------------------------------------

  defp sigma_info(subject) do
    Sessions.with_session(subject, :sigma, fn token ->
      with {:ok, data} <- Sigma.fetch(token, "/Estudiante/MostrarInfoEstudiante") do
        {:ok, first_map(data), token}
      end
    end)
  end

  defp sigma_summary(_subject, nil), do: {:error, :unavailable}

  defp sigma_summary(subject, info) do
    with plan when is_binary(plan) <- Normalize.text(info["pes_Id"]),
         level when is_binary(level) <- Normalize.text(info["nivel"]) do
      Sessions.with_session(subject, :sigma, fn token ->
        with {:ok, data} <-
               Sigma.fetch(token, "/Estudiante/MostrarNotasResumen/#{plan}/#{level}") do
          {:ok, first_map(data), token}
        end
      end)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp intranet_basic(subject) do
    Sessions.with_session(subject, :intranet, fn cookies ->
      with {:ok, rows, cookies} <- Intranet.get(cookies, "datosEstudianteMatriculado", "inicio") do
        {:ok, first_row(rows), cookies}
      end
    end)
  end

  @doc """
  Raw rows of the Intranet enrollment certificate for `term` (one per course,
  student data repeated in each). Shared with `Nexo.Academic.Enrollment`.
  """
  def intranet_certificate(_subject, nil), do: {:error, :unavailable}

  def intranet_certificate(subject, term) do
    Sessions.with_session(subject, :intranet, fn cookies ->
      with {:ok, rows, cookies} <-
             Intranet.post(
               cookies,
               "consultarConstanciaMatriculaEstudiante",
               %{"periodo" => "#{term.year}-#{term.number}"},
               "pg_reportesDelEstudiante"
             ) do
        {:ok, Enum.filter(rows, &(is_list(&1) and length(&1) >= 18)), cookies}
      end
    end)
  end

  # --- Building -------------------------------------------------------------------

  @doc false
  def build(student, info, summary, datos, certificate, active) do
    info = info || %{}
    summary = summary || %{}
    datos = datos || []
    rows = certificate || []
    header = List.first(rows) || []
    at = fn list, i -> Enum.at(list, i) end

    code =
      Normalize.text(info["est_Id"]) || Normalize.text(at.(header, 0)) ||
        student["code"]

    first = Normalize.text(student["first_name"])
    last = Normalize.text(student["last_name"])

    full =
      [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> Normalize.text() ||
        Normalize.title(info["estudiante"] || at.(header, 1))

    enrolled_courses = Enum.filter(rows, &Normalize.text(at.(&1, 6)))

    enrolled_credits =
      Normalize.int(at.(header, 17)) ||
        case enrolled_courses do
          [] -> nil
          list -> list |> Enum.map(&(Normalize.int(at.(&1, 13)) || 0)) |> Enum.sum()
        end

    last_enrollment =
      Normalize.text(info["ultimaMatricula"]) ||
        case {Normalize.int(at.(header, 11)), Normalize.int(at.(header, 12))} do
          {y, n} when is_integer(y) and is_integer(n) -> "#{y}-#{n}"
          _ -> nil
        end

    %{
      code: code,
      name: %{first: first, last: last, full: full},
      photo_url: Normalize.photo_url(code),
      faculty: Normalize.title(info["facultad"] || at.(header, 2)),
      career: Normalize.title(info["carrera"] || at.(header, 4)),
      specialty: Normalize.title(at.(header, 5)),
      campus: Normalize.campus(info["sede"] || at.(datos, 6)),
      modality: Normalize.modality(info["modalidad"] || at.(header, 14)),
      study_plan:
        Normalize.text(info["pes_Id"]) || Normalize.text(at.(header, 8)) ||
          Normalize.text(at.(datos, 4)),
      current_cycle:
        Normalize.int(info["nivel"]) || Normalize.int(at.(header, 18)) ||
          Normalize.int(at.(header, 9)),
      enrolled:
        Normalize.bool(info["matriculado"]) or enrolled_courses != [] or
          (active != nil and last_enrollment == "#{active.year}-#{active.number}"),
      last_enrollment: last_enrollment,
      credits: %{
        approved:
          int_or_nil(Normalize.positive(info["creditoAprobado"])) ||
            int_or_nil(Normalize.positive(summary["creditosAprobados"])),
        required: int_or_nil(Normalize.positive(summary["creditosTotales"])),
        enrolled_this_term: enrolled_credits
      },
      average: %{cumulative: round2(Normalize.positive(summary["promedio"]))}
    }
  end

  # --- Helpers --------------------------------------------------------------------

  defp first_map(data) when is_map(data), do: data
  defp first_map([first | _]) when is_map(first), do: first
  defp first_map(_), do: nil

  defp first_row([first | _]) when is_list(first), do: first
  defp first_row(_), do: nil

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil

  defp worst(results) do
    cond do
      Enum.any?(results, &match?({:error, :reauth_required}, &1)) -> "reauth_required"
      Enum.all?(results, &match?({:ok, _}, &1)) -> "ok"
      Enum.any?(results, &match?({:ok, _}, &1)) -> "partial"
      true -> "unavailable"
    end
  end

  defp fallback("unavailable", other) when is_binary(other), do: other
  defp fallback(status, _), do: status

  defp int_or_nil(nil), do: nil
  defp int_or_nil(n), do: round(n)

  defp round2(nil), do: nil
  defp round2(n), do: Float.round(n * 1.0, 2)
end
