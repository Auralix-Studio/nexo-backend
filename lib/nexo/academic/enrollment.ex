defmodule Nexo.Academic.Enrollment do
  @moduledoc """
  Data for the enrollment certificate of a term (the PDF is drawn in the
  app), from the Intranet's `consultarConstanciaMatriculaEstudiante`.

  Upstream sends one 22-column row per course with the student's data
  repeated: 0 code, 1 name, 2 faculty, 4 career, 5 specialty, 6 course code,
  7 course name, 8 study plan, 9 course cycle, 10 section, 11 year, 12 term,
  13 credits, 14 modality, 17 total credits, 18 student cycle, 19 photo,
  21 career label. Placeholders (`-------`) become `null`, numbers become
  numbers, names lose the all-caps.
  """
  alias Nexo.Academic.{Profile, Terms}
  alias Nexo.Upstream.Normalize

  @doc "`{:ok, enrollment, meta}` or `{:error, :reauth_required | :unknown_term | :unavailable}`."
  def get(subject, student, term_id \\ nil) do
    with {:ok, term} <- Terms.resolve(subject, term_id),
         {:ok, rows} <- Profile.intranet_certificate(subject, term) do
      {:ok, build(rows, term, student, lima_today()), %{source: "intranet"}}
    end
  end

  @doc false
  def build(rows, term, student, today) do
    header = List.first(rows) || []
    at = &Enum.at(header, &1)

    courses =
      for row <- rows,
          code = Normalize.text(Enum.at(row, 6)),
          code != nil,
          do: %{
            code: code,
            name: Normalize.title(Enum.at(row, 7)),
            cycle: Normalize.int(Enum.at(row, 9)),
            section: Normalize.text(Enum.at(row, 10)),
            credits: tidy(Normalize.number(Enum.at(row, 13)))
          }

    total =
      Normalize.number(at.(17)) ||
        Enum.reduce(courses, 0, &((&1.credits || 0) + &2))

    %{
      term: %{id: term.id, label: term.label},
      student: %{
        code: Normalize.text(at.(0)) || student["code"],
        name: Normalize.title(at.(1)),
        photo_url: Normalize.text(at.(19))
      },
      faculty: Normalize.title(at.(2)),
      career: %{
        label: Normalize.text(at.(21)) || "Carrera",
        name: Normalize.title(at.(4))
      },
      specialty: Normalize.title(at.(5)),
      study_plan: Normalize.text(at.(8)),
      cycle: Normalize.int(at.(18)) || Normalize.int(at.(9)),
      modality: Normalize.modality(at.(14)),
      courses: courses,
      total_credits: tidy(total),
      issued_at: Date.to_iso8601(today)
    }
  end

  defp tidy(nil), do: nil
  defp tidy(n) when is_float(n) and n == trunc(n), do: trunc(n)
  defp tidy(n), do: n

  defp lima_today, do: DateTime.utc_now() |> DateTime.add(-5 * 3600) |> DateTime.to_date()
end
