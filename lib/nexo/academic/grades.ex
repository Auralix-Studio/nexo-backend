defmodule Nexo.Academic.Grades do
  @moduledoc """
  The student's grades: a term's courses, one course's units, the academic
  summary and the curriculum, each in one clean shape.

  Upstream has two grading models behind the same Intranet endpoint
  (`consultarconstanciaNotasDetallado`):

    * `competencies` (2026-1 on): 11 positional columns per course, plus a
      per-course detail (`consultarDetalleBoletaNotas`) tagged by table
      (`tbl1` evidences, `tbl3` unit averages, `tbl5` make-up exam, `tbl6`
      final). While a course is in progress its "average" column holds the
      points accumulated so far (14 on a 20 % unit shows as 2.8) and the
      official column rounds that, so the real current average is computed
      here from the units.
    * `legacy` (before 2026-1): 50 positional columns (SIGMA serves the same
      data keyed by name, used as fallback), two halves with practices,
      individual work, project and partial exam.

  Fixes over the app's reading:

    * credits come only from the credits column (the app fell back to the
      cycle column);
    * the current average weighs graded evidences and units by their weight
      (the app used a plain mean);
    * workshops graded on 0–100 come back on 0–20;
    * the curriculum reads cycle (col 5) and credits (col 8) from the right
      columns.

  Course ids are the course code: the university's enrollment ids stay here.
  """
  import Nexo.Upstream.Normalize, only: [tidy: 1]
  alias Nexo.Academic.{Profile, Terms}
  alias Nexo.Infra.Cache
  alias Nexo.Upstream.{Intranet, Normalize, Sessions}

  @passing 10.5
  @max 20
  @referer "repRankingPromocionalEst"

  # Cache times per user: the active term's grades move, closed terms and
  # the curriculum barely do.
  @active_ttl :timer.minutes(5)
  @closed_ttl :timer.hours(24)
  @summary_ttl :timer.minutes(5)
  @averages_ttl :timer.hours(6)
  @empty_averages_ttl :timer.minutes(30)
  @curriculum_ttl :timer.hours(6)
  # In-progress course details fetched at once (`:grade_detail_concurrency`;
  # 1 if the Intranet turns out to serialize requests of one PHP session).
  @detail_concurrency 4

  @legacy_keys ~w(nombreFacultad nombreCarrera planEstudios codigo asignatura plan ciclo
    seccion credito asistencia pF1 pF2 pf complementario pfp cc cicloTotal seccionTotal
    creditosTotal mtr_Anio mtr_Periodo tipoAsignatura tar_Id puesto p1 p2 p3 p4 p5 p6 p7 p8
    ntaP1 ntaTI1 ntaPY1 ntaPromTiPy ntaParcial1 _2P1 _2P2 _2P3 _2P4 _2P5 _2P6 _2P7 _2P8
    _2NtaP1 _2NtaTI1 _2NtaPY1 _2NtaPromTiPy _2NtaParcial1)

  @doc "Passing grade on the 0–20 scale."
  def passing, do: @passing

  # --- Term grades ----------------------------------------------------------------------

  @doc """
  `{:ok, term_grades, meta}` or `{:error, :reauth_required | :unknown_term |
  :unavailable}`.
  """
  def term(subject, term_id \\ nil) do
    with {:ok, term} <- Terms.resolve(subject, term_id),
         {:ok, courses, source} <- cached_courses(subject, term) do
      model = model(term)

      {:ok,
       %{
         term: %{id: term.id, label: term.label},
         model: model,
         scale: %{max: @max, passing: @passing},
         average: average(courses),
         courses: Enum.map(courses, &public/1)
       }, %{source: source}}
    end
  end

  @doc """
  `{:ok, course_grades, meta}` or `{:error, :unknown_course | …}`. Only that
  course's detail is fetched (the term's list is reused when cached).
  """
  def course(subject, term_id, code) do
    with {:ok, term} <- Terms.resolve(subject, term_id) do
      Cache.subject(
        subject,
        {:grade_course, term.id, code},
        fn -> fetch_course(subject, term, code) end,
        ttl: term_ttl(term)
      )
    end
  end

  defp fetch_course(subject, term, code) do
    with {:ok, courses, source} <- course_list(subject, term),
         %{} = course <- Enum.find(courses, &(&1.id == code)) || {:error, :unknown_course},
         {:ok, course} <- with_units(subject, term, course) do
      units = course.units || []

      {:ok,
       %{
         course: %{
           id: course.id,
           code: course.code,
           name: course.name,
           credits: course.credits
         },
         units: units,
         makeup_exam: course.makeup_exam,
         final: %{
           current: course.grade.current,
           official: course.grade.official,
           status: course.status
         },
         projection: projection(units, course.closed)
       }, %{source: source}}
    end
  end

  defp model(%{year: year, number: number}) do
    if {year, number} >= {2026, 1}, do: "competencies", else: "legacy"
  end

  defp term_ttl(%{active: true}), do: @active_ttl
  defp term_ttl(_closed), do: @closed_ttl

  # The term's courses with the details of those in progress, cached.
  defp cached_courses(subject, term) do
    Cache.subject(
      subject,
      {:grade_courses, term.id},
      fn -> courses(subject, term, :in_progress) end,
      ttl: term_ttl(term)
    )
  end

  # For one course: the cached full list if there is one, else only the
  # list (no details).
  defp course_list(subject, term) do
    case Cache.peek_subject(subject, {:grade_courses, term.id}) do
      {:ok, {:ok, _, _} = cached} -> cached
      _ -> courses(subject, term, :none)
    end
  end

  defp courses(subject, term, details) do
    case model(term) do
      "competencies" -> competencies(subject, term, details)
      "legacy" -> legacy(subject, term)
    end
  end

  defp form(term), do: %{"anio" => "#{term.year}", "periodo" => "#{term.number}"}

  # --- Competencies model -----------------------------------------------------------

  defp competencies(subject, term, details) do
    result =
      Sessions.with_session(subject, :intranet, fn cookies ->
        with {:ok, rows, cookies} <-
               Intranet.post(cookies, "consultarconstanciaNotasDetallado", form(term), @referer) do
          courses =
            for row <- rows,
                is_list(row),
                length(row) in 11..23,
                course = competency_course(row),
                do: course

          {:ok, with_details(details, cookies, term, courses), cookies}
        end
      end)

    case result do
      {:ok, courses} -> {:ok, courses, "intranet"}
      {:error, _} = error -> error
    end
  end

  @doc false
  def competency_course(row) do
    at = &Enum.at(row, &1)
    upstream_id = Normalize.text(at.(0))
    code = Normalize.text(at.(4))
    name = Normalize.title(at.(5))

    if upstream_id && code && name do
      raw = Normalize.number(at.(8))
      official = Normalize.number(at.(9))
      status = competency_status(at.(10), official)
      closed = status in ["passed", "failed"]

      current =
        cond do
          not closed -> nil
          raw && raw <= @max + 0.5 -> raw
          true -> official
        end

      %{
        upstream_id: upstream_id,
        id: code,
        code: code,
        name: name,
        section: Normalize.text(at.(6)),
        cycle: Normalize.int(at.(2)),
        credits: tidy(Normalize.number(at.(3))),
        type: nil,
        attendance_percent: Normalize.int(at.(7)),
        status: status,
        grade: %{current: tidy(current), official: tidy(official)},
        makeup_exam: nil,
        rank: nil,
        closed: closed,
        units: nil
      }
    end
  end

  defp competency_status(value, official) do
    case value |> Normalize.text() |> to_string() |> String.downcase() do
      "apr" <> _ -> "passed"
      "des" <> _ -> "failed"
      "dsp" <> _ -> "in_progress"
      _ when is_number(official) -> pass_or_fail(official)
      _ -> "not_graded"
    end
  end

  defp pass_or_fail(grade), do: if(grade >= @passing, do: "passed", else: "failed")

  # In-progress courses need their detail for the real current average; the
  # rest keep the official grade until someone opens them. The details are
  # fetched a few at a time, not one after another.
  defp with_details(:none, _cookies, _term, courses), do: courses

  defp with_details(:in_progress, cookies, term, courses) do
    courses
    |> Task.async_stream(&in_progress_units(cookies, term, &1),
      max_concurrency: Application.get_env(:nexo, :grade_detail_concurrency, @detail_concurrency),
      timeout: 15_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(courses)
    |> Enum.map(fn
      {{:ok, course}, _} -> course
      {{:exit, _}, course} -> course
    end)
  end

  defp in_progress_units(cookies, term, %{status: "in_progress"} = course) do
    case detail_rows(cookies, term, course.upstream_id) do
      {:ok, rows} -> apply_detail(course, rows)
      _ -> course
    end
  end

  defp in_progress_units(_cookies, _term, course), do: course

  defp detail_rows(cookies, term, upstream_id) do
    form = Map.put(form(term), "matricula_asignatura_id", upstream_id)

    case Intranet.post(cookies, "consultarDetalleBoletaNotas", form, @referer) do
      {:ok, rows, _} -> {:ok, rows}
      error -> error
    end
  end

  defp with_units(_subject, _term, %{units: units} = course) when is_list(units),
    do: {:ok, course}

  defp with_units(subject, term, course) do
    Sessions.with_session(subject, :intranet, fn cookies ->
      with {:ok, rows} <- detail_rows(cookies, term, course.upstream_id) do
        {:ok, apply_detail(course, rows), cookies}
      end
    end)
  end

  defp apply_detail(course, rows) do
    detail = parse_detail(rows, course.status == "in_progress")
    current = weighted(detail.units) || course.grade.current

    %{
      course
      | units: detail.units,
        makeup_exam: detail.makeup_exam,
        grade: %{course.grade | current: tidy(current)}
    }
  end

  @doc """
  Units, make-up exam and final grade from the detail rows. Duplicate tables
  (`tbl2`, `tbl4`) are dropped. While the course is in progress a `0` is an
  evidence not graded yet.
  """
  def parse_detail(rows, in_progress?) do
    rows = for r <- rows, is_list(r), length(r) >= 12, do: r
    table = fn tag -> Enum.filter(rows, &(Enum.at(&1, 11) == tag)) end

    unit_averages =
      Map.new(table.("tbl3"), fn r ->
        {Normalize.text(Enum.at(r, 4)), grade(Enum.at(r, 9), in_progress?)}
      end)

    units =
      table.("tbl1")
      |> Enum.chunk_by(&Normalize.text(Enum.at(&1, 4)))
      |> Enum.with_index(1)
      |> Enum.map(fn {[first | _] = evidence_rows, number} ->
        name = Normalize.text(Enum.at(first, 4))

        evidences =
          Enum.map(evidence_rows, fn r ->
            label = Normalize.text(Enum.at(r, 7))

            %{
              type: evidence_type(label),
              label: Normalize.title(label),
              weight_percent: tidy(Normalize.number(Enum.at(r, 8))),
              grade: tidy(grade(Enum.at(r, 9), in_progress?))
            }
          end)

        %{
          number: number,
          name: Normalize.title(name),
          weight_percent: tidy(Normalize.number(Enum.at(first, 5))),
          average: tidy(evidence_average(evidences) || unit_averages[name]),
          evidences: evidences
        }
      end)

    final = List.first(table.("tbl6"))

    %{
      units: units,
      makeup_exam: tidy(rows |> table_value("tbl5")),
      final: final && tidy(Normalize.number(Enum.at(final, 9)))
    }
  end

  defp table_value(rows, tag) do
    case Enum.find(rows, &(Enum.at(&1, 11) == tag)) do
      nil -> nil
      r -> Normalize.number(Enum.at(r, 9))
    end
  end

  defp grade(value, in_progress?) do
    case Normalize.number(value) do
      n when in_progress? and n == 0 -> nil
      n -> n
    end
  end

  defp evidence_type(nil), do: "other"

  defp evidence_type(label) do
    l = String.downcase(label)

    cond do
      l =~ "conocimiento" -> "knowledge"
      l =~ "desempe" -> "performance"
      l =~ "producto" -> "product"
      true -> "other"
    end
  end

  defp evidence_average(evidences) do
    evidences
    |> Enum.map(&{&1.grade, &1.weight_percent})
    |> weighted_pairs()
  end

  # Weighted by `weight_percent` when every graded item has one, else a plain mean.
  defp weighted(units) do
    units
    |> Enum.map(&{&1.average, &1.weight_percent})
    |> weighted_pairs()
  end

  defp weighted_pairs(pairs) do
    graded = Enum.filter(pairs, fn {value, _} -> is_number(value) end)

    cond do
      graded == [] ->
        nil

      Enum.all?(graded, fn {_, w} -> is_number(w) and w > 0 end) ->
        total = Enum.reduce(graded, 0, fn {_, w}, acc -> acc + w end)
        Enum.reduce(graded, 0, fn {v, w}, acc -> acc + v * w end) / total

      true ->
        Enum.reduce(graded, 0, fn {v, _}, acc -> acc + v end) / length(graded)
    end
  end

  @doc """
  What average the ungraded units need to reach the passing grade. Weights
  are the units' when all have one, equal otherwise.
  """
  def projection(units, closed?) do
    base = %{target: @passing, needed_average: nil}
    graded = Enum.filter(units, &is_number(&1.average))

    cond do
      closed? ->
        Map.put(base, :status, "closed")

      graded == [] ->
        Map.put(base, :status, "no_data")

      true ->
        weight =
          if Enum.all?(units, &(is_number(&1.weight_percent) and &1.weight_percent > 0)),
            do: & &1.weight_percent,
            else: fn _ -> 1 end

        total = units |> Enum.map(weight) |> Enum.sum()
        graded_weight = graded |> Enum.map(weight) |> Enum.sum()
        obtained = graded |> Enum.map(&(&1.average * weight.(&1))) |> Enum.sum()
        pending = total - graded_weight

        cond do
          obtained >= @passing * total ->
            Map.put(base, :status, "already_passed")

          pending <= 0 ->
            Map.put(base, :status, "impossible")

          true ->
            needed = (@passing * total - obtained) / pending

            if needed <= @max,
              do: %{base | needed_average: tidy(max(needed, 0))} |> Map.put(:status, "reachable"),
              else: Map.put(base, :status, "impossible")
        end
    end
  end

  # --- Legacy model ---------------------------------------------------------------------

  defp legacy(subject, term) do
    intranet =
      with {:ok, rows} <-
             Sessions.intranet_post(
               subject,
               "consultarconstanciaNotasDetallado",
               form(term),
               @referer
             ) do
        {:ok,
         for(
           row <- rows,
           is_list(row),
           length(row) >= 24,
           do: Map.new(Enum.zip(@legacy_keys, row))
         )}
      end

    case intranet do
      {:ok, [_ | _] = maps} ->
        {:ok, legacy_courses(maps), "intranet"}

      _ ->
        path = "/Intranet/ListarNotasEstudianteIntranet/#{term.year}/#{term.number}"

        sigma =
          with {:ok, data} <- Sessions.sigma_fetch(subject, path),
               do: {:ok, Enum.filter(List.wrap(data), &is_map/1)}

        case {intranet, sigma} do
          {_, {:ok, [_ | _] = maps}} -> {:ok, legacy_courses(maps), "sigma"}
          {{:ok, []}, _} -> {:ok, [], "intranet"}
          {_, {:ok, []}} -> {:ok, [], "sigma"}
          {{:error, :reauth_required}, {:error, :reauth_required}} -> {:error, :reauth_required}
          _ -> {:error, :unavailable}
        end
    end
  end

  defp legacy_courses(maps) do
    maps
    |> Enum.map(&legacy_course/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def legacy_course(m) do
    code = Normalize.text(m["codigo"])
    name = Normalize.title(m["asignatura"])

    if code && name do
      n = &Normalize.number(m[&1])
      closed = Normalize.bool(m["cc"])
      official = n.("pfp") || n.("pf")
      units = [legacy_half(m, 1), legacy_half(m, 2)]
      current = if closed, do: official, else: n.("pf") || weighted(units)

      status =
        cond do
          closed and is_number(official) -> pass_or_fail(official)
          is_number(current) -> "in_progress"
          true -> "not_graded"
        end

      %{
        upstream_id: nil,
        id: code,
        code: code,
        name: name,
        section: Normalize.text(m["seccion"]),
        cycle: Normalize.int(m["ciclo"]),
        credits: tidy(n.("credito")),
        type: course_type(m["tipoAsignatura"]),
        attendance_percent: Normalize.int(m["asistencia"]),
        status: status,
        grade: %{current: tidy(current), official: tidy(official)},
        makeup_exam: tidy(n.("complementario")),
        rank: rank(m["puesto"]),
        closed: closed,
        units: units
      }
    end
  end

  defp legacy_half(m, half) do
    # Half 1 keys are `p1`, `ntaTI1`…; half 2 repeats them as `_2P1`, `_2NtaTI1`….
    key = fn first, second -> if half == 1, do: first, else: second end
    n = &Normalize.number(m[&1])

    practices =
      for i <- 1..8,
          grade = n.(key.("p#{i}", "_2P#{i}")),
          do: %{type: "practice", label: "Práctica #{i}", weight_percent: nil, grade: tidy(grade)}

    others =
      for {first, second, type, label} <- [
            {"ntaTI1", "_2NtaTI1", "individual_work", "Trabajo individual"},
            {"ntaPY1", "_2NtaPY1", "project", "Proyecto"},
            {"ntaParcial1", "_2NtaParcial1", "partial_exam", "Examen parcial"}
          ],
          grade = n.(key.(first, second)),
          do: %{type: type, label: label, weight_percent: nil, grade: tidy(grade)}

    %{
      number: half,
      name: "Unidad #{half}",
      weight_percent: 50,
      average: tidy(n.("pF#{half}")),
      practices_average: tidy(n.(key.("ntaP1", "_2NtaP1"))),
      work_average: tidy(n.(key.("ntaPromTiPy", "_2NtaPromTiPy"))),
      evidences: practices ++ others
    }
  end

  @doc "`TN/TE/TA/TT/TP` → closed English words (meaning of `TA`/`TT`/`TP` unconfirmed)."
  def course_type(value) do
    case value |> Normalize.text() |> to_string() |> String.upcase() do
      "TN" -> "mandatory"
      "TE" -> "elective"
      "TA" -> "activity"
      "TT" -> "workshop"
      "TP" -> "practicum"
      _ -> nil
    end
  end

  defp rank(value) do
    with t when is_binary(t) <- Normalize.text(value),
         [p, o] <- String.split(t, "/"),
         position when is_integer(position) <- Normalize.int(p),
         of when is_integer(of) <- Normalize.int(o) do
      %{position: position, of: of}
    else
      _ -> nil
    end
  end

  # --- Shared -------------------------------------------------------------------------

  defp public(course), do: Map.delete(course, :upstream_id)

  @doc false
  def average(courses) do
    with_credits = Enum.filter(courses, &(is_number(&1.credits) and &1.credits > 0))

    pick = fn key ->
      graded = Enum.filter(with_credits, &is_number(&1.grade[key]))

      case graded do
        [] ->
          nil

        _ ->
          credits = graded |> Enum.map(& &1.credits) |> Enum.sum()
          tidy(Enum.reduce(graded, 0, &(&1.grade[key] * &1.credits + &2)) / credits)
      end
    end

    %{
      value: pick.(:current),
      official: pick.(:official),
      credits: with_credits |> Enum.map(& &1.credits) |> Enum.sum() |> tidy()
    }
  end

  # --- Summary --------------------------------------------------------------------------

  @doc """
  `{:ok, summary, meta}` or `{:error, :reauth_required}`. Reuses the cached
  profile and active-term grades; cached 5 min per user when every source
  answered.
  """
  def summary(subject, student) do
    Cache.subject(subject, :grades_summary, fn -> fetch_summary(subject, student) end,
      ttl: @summary_ttl,
      cache_if: &match?({:ok, _, %{sources: s}} when s == %{sigma: "ok", intranet: "ok"}, &1)
    )
  end

  defp fetch_summary(subject, student) do
    [profile, averages, current] =
      [
        fn -> Profile.get(subject, student) end,
        fn -> term_averages(subject) end,
        fn -> term(subject) end
      ]
      |> Task.async_stream(& &1.(), timeout: 60_000, on_timeout: :kill_task, ordered: true)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> {:error, :unavailable}
      end)

    if Enum.all?([profile, averages, current], &match?({:error, :reauth_required}, &1)) do
      {:error, :reauth_required}
    else
      profile =
        case profile do
          {:ok, p, _} -> p
          _ -> %{}
        end

      {:ok,
       %{
         cumulative_average: get_in(profile, [:average, :cumulative]),
         credits: %{
           approved: get_in(profile, [:credits, :approved]),
           required: get_in(profile, [:credits, :required])
         },
         terms:
           case averages do
             {:ok, [_ | _] = list} -> list
             _ -> computed_term_averages(subject)
           end,
         current_term: current_term(current)
       },
       %{
         sources: %{
           sigma: Sessions.status(averages),
           intranet: Sessions.status(current)
         }
       }}
    end
  end

  defp current_term({:ok, grades, _}) do
    count = &Enum.count(grades.courses, fn c -> c.status in &1 end)

    %{
      term: grades.term.id,
      partial_average: grades.average.value,
      passed: count.(["passed"]),
      failed: count.(["failed"]),
      pending: count.(["in_progress", "not_graded"])
    }
  end

  defp current_term(_), do: nil

  # SIGMA's per-term averages come back empty for some accounts; then each
  # past term's own grades give its credit-weighted average. Cached per
  # student, `:empty` too (shorter), so an account without them does not
  # recompute every past term on each call.
  # SIGMA's per-term averages come back empty for some accounts; then each
  # past term's own grades give its average. That is one university read per
  # term (up to 14), too slow for a request's time budget, so it runs in the
  # background (started at login and on the first summary that misses it)
  # and the summary returns whatever is already computed.
  defp computed_term_averages(subject) do
    case Cache.peek_subject(subject, :computed_term_averages) do
      {:ok, {:ok, rows}} ->
        rows

      {:ok, _empty} ->
        []

      :miss ->
        warm_term_averages(subject)
        []
    end
  end

  @doc """
  Computes the per-term averages of `subject` in a background process (no
  request deadline) and caches them. Safe to call often: one computation per
  student at a time.
  """
  def warm_term_averages(subject) do
    if Application.get_env(:nexo, :warm_term_averages, true), do: spawn_warm(subject)
    :ok
  end

  defp spawn_warm(subject) do
    # `spawn`, not Task: a Task would inherit the caller's request deadline.
    spawn(fn ->
      Cache.subject(subject, :computed_term_averages, fn -> compute_term_averages(subject) end,
        ttl: &if(&1 == :empty, do: @empty_averages_ttl, else: @averages_ttl),
        cache_if: &(&1 != :failed)
      )
    end)
  end

  defp compute_term_averages(subject) do
    case Terms.list(subject) do
      {:ok, terms, _} ->
        results =
          terms
          |> Enum.reject(& &1.active)
          |> Enum.take(14)
          |> Task.async_stream(
            fn t ->
              case term(subject, t.id) do
                {:ok, %{average: %{value: v}}, _} when is_number(v) ->
                  {:row, %{term: t.id, average: v}}

                {:ok, _, _} ->
                  :no_average

                _ ->
                  :failed
              end
            end,
            max_concurrency: 2,
            timeout: 60_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            _ -> :failed
          end)

        rows = for {:row, row} <- results, do: row

        cond do
          rows != [] -> {:ok, rows}
          # Only "nothing to show" when every term answered.
          Enum.any?(results, &(&1 == :failed)) -> :failed
          true -> :empty
        end

      _ ->
        :failed
    end
  end

  defp term_averages(subject) do
    Cache.subject(subject, :term_averages, fn -> fetch_term_averages(subject) end,
      ttl: @averages_ttl
    )
  end

  defp fetch_term_averages(subject) do
    with {:ok, data} <- Sessions.sigma_fetch(subject, "/Estudiante/ListarPromediosResumen") do
      rows =
        for row <- List.wrap(data),
            is_map(row),
            year = Normalize.int(row["anio"]),
            number = Normalize.int(row["periodo"]),
            is_integer(year) and is_integer(number),
            average = Normalize.positive(row["promedio"]),
            do: {{year, number}, %{term: "#{year}-#{number}", average: tidy(average)}}

      {:ok, rows |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))}
    end
  end

  # --- Curriculum -----------------------------------------------------------------------

  @doc "`{:ok, curriculum, meta}` or `{:error, :reauth_required | :unavailable}`."
  def curriculum(subject, student) do
    Cache.subject(subject, :curriculum, fn -> fetch_curriculum(subject, student) end,
      ttl: @curriculum_ttl
    )
  end

  defp fetch_curriculum(subject, student) do
    form = %{"codest" => to_string(student["code"])}

    with {:ok, rows} <-
           Sessions.intranet_post(
             subject,
             "consultarProgresoCurricular",
             form,
             "repProgresoCurricularEst"
           ) do
      rows = for r <- rows, is_list(r), length(r) >= 13, do: r
      courses = rows |> Enum.map(&curriculum_course/1) |> Enum.reject(&is_nil/1)
      first = List.first(rows) || []
      completed = Enum.filter(courses, &(&1.status == "completed"))
      credits = &(&1 |> Enum.map(fn c -> c.credits || 0 end) |> Enum.sum() |> tidy())

      {:ok,
       %{
         plan: Normalize.text(Enum.at(first, 2)),
         career: Normalize.title(Enum.at(first, 1)),
         progress: %{
           completed_courses: length(completed),
           pending_courses: length(courses) - length(completed),
           credits_completed: credits.(completed),
           credits_total: credits.(courses)
         },
         courses: Enum.sort_by(courses, &{&1.cycle || 99, &1.code})
       }, %{source: "intranet"}}
    end
  end

  @doc false
  def curriculum_course(r) do
    at = &Enum.at(r, &1)
    code = Normalize.text(at.(6))
    name = Normalize.title(at.(7))

    if code && name do
      state = at.(3) |> Normalize.text() |> to_string() |> String.downcase()

      status =
        cond do
          state =~ "conclu" -> "completed"
          state =~ "curso" or state =~ "proceso" -> "in_progress"
          true -> "pending"
        end

      %{
        code: code,
        name: name,
        cycle: Normalize.int(at.(5)),
        credits: tidy(Normalize.number(at.(8))),
        type: course_type(at.(4)),
        status: status,
        grade: tidy(Normalize.number(at.(12))),
        attempts: Normalize.int(at.(14)) || 0
      }
    end
  end
end
