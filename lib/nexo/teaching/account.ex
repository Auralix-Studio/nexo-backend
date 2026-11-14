defmodule Nexo.Teaching.Account do
  @moduledoc """
  What the teacher app still read straight from SIGMA: the teacher's own
  profile (`Login/GetDatosEntidad`), SIGMA's clock (`Docente/GetHora`) and a
  section's auxiliary register (`Docente/GetReporteAuxiliar`, PDF or XLSX).
  """
  alias Nexo.Sigma
  alias Nexo.Teaching.{Attendance, Sections, Upstream}
  alias Nexo.Upstream.{Normalize, Sessions}

  @formats %{
    "pdf" => "application/pdf",
    "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  }

  @doc "`{:ok, profile, meta}` or an error."
  def me(subject) do
    with {:ok, data} <- Upstream.get(subject, "/Login/GetDatosEntidad") do
      data = if is_map(data), do: data, else: %{}
      post = if is_map(data["dependencia"]), do: data["dependencia"], else: %{}
      first = Normalize.title(data["nombres"])
      last = Normalize.title(data["apellidos"])
      code = Normalize.text(data["codigo"])

      {:ok,
       %{
         code: code,
         first_name: first,
         last_name: last,
         full_name: [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> Normalize.text(),
         faculty: Normalize.title(post["facultad"]),
         specialty: Normalize.title(post["cargo"] || post["condicion"]),
         photo_url: code && Normalize.photo_url(code)
       }, %{source: "sigma"}}
    end
  end

  @doc """
  SIGMA's clock as Lima wall time (its sub-second part dropped), or the
  backend's clock in Lima when SIGMA does not answer.
  """
  def server_time(subject) do
    sigma =
      case Upstream.get(subject, "/Docente/GetHora") do
        {:ok, raw} -> Attendance.session_id(raw)
        _ -> nil
      end

    if sigma do
      {:ok, %{now: sigma <> "-05:00"}, %{source: "sigma"}}
    else
      {:ok, %{now: NaiveDateTime.to_iso8601(Normalize.lima_now()) <> "-05:00"},
       %{source: "server"}}
    end
  end

  @doc """
  The auxiliary register of a section the teacher owns:
  `{:ok, %{body, content_type, filename}}` or an error.
  """
  def report(subject, section_id, format) do
    format = if Map.has_key?(@formats, format), do: format, else: "pdf"

    with {:ok, section} <- Sections.resolve(subject, section_id) do
      query = %{
        "codSaltem" => to_string(section.upstream.cle_auto || section.upstream.attendance_ids),
        "plan" => to_string(section.upstream.plan),
        "asignID" => to_string(section.upstream.nrc),
        "tipo" => format,
        "tipoCalif" => "#{section.upstream.grading_type}"
      }

      result =
        Sessions.with_session(subject, :sigma, fn token ->
          with {:ok, file} <- Sigma.download(token, "/Docente/GetReporteAuxiliar", query),
               do: {:ok, file, token}
        end)

      with {:ok, file} <- result do
        {:ok,
         %{
           body: file.body,
           content_type: @formats[format],
           filename:
             "Registro auxiliar #{safe(section.course.name)} #{safe(section.section)}.#{format}"
         }}
      end
    end
  end

  # Header-safe file name parts: ASCII letters, digits, spaces and dashes.
  defp safe(nil), do: ""

  defp safe(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9 _-]/u, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
