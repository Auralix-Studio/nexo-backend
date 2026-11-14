defmodule Nexo.Upstream.Normalize do
  @moduledoc """
  Turns the university's loosely typed values into clean ones.

  SIGMA and the Intranet send numbers and booleans as strings, pad values
  with spaces, and use placeholders (`""`, `" "`, `"-"`, `"--"`,
  `"No hay datos"`) for "nothing". Every function here returns a proper
  value or `nil`, never a placeholder.
  """

  @blanks ["", "-", "--", "---", "-------", "null", "undefined"]

  @doc "Trimmed text, or `nil` for blanks and placeholders."
  def text(nil), do: nil

  def text(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed in @blanks -> nil
      String.downcase(trimmed) |> String.starts_with?("no hay") -> nil
      true -> trimmed
    end
  end

  def text(value) when is_integer(value) or is_float(value), do: to_string(value)
  def text(_), do: nil

  @doc "Integer from `3`, `\"03\"`, `\"3.000\"`; `nil` otherwise."
  def int(value) when is_integer(value), do: value
  def int(value) when is_float(value), do: trunc(value)

  def int(value) do
    case number(value) do
      nil -> nil
      n -> trunc(n)
    end
  end

  @doc "Number from `\"522.5\"`, `\"11,60\"`, `\"15   \"`; `nil` otherwise."
  def number(value) when is_integer(value), do: value * 1.0
  def number(value) when is_float(value), do: value

  def number(value) when is_binary(value) do
    case value |> text() do
      nil ->
        nil

      t ->
        case Float.parse(String.replace(t, ",", ".")) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  def number(_), do: nil

  @doc "Positive number or `nil` (upstream uses 0 for \"no data\")."
  def positive(value) do
    case number(value) do
      n when is_number(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "Booleans as SIGMA and the Intranet spell them."
  def bool(true), do: true
  def bool(false), do: false
  def bool(1), do: true
  def bool(0), do: false

  def bool(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["true", "1", "s", "si", "sí", "y", "yes"]
  end

  def bool(_), do: false

  @doc """
  ISO date from `dd/MM/yyyy`, `dd-MM-yyyy`, `yyyy-MM-dd` (with or without a
  time part). `nil` when it cannot be read.
  """
  def date(value) when is_binary(value) do
    t = String.trim(value)

    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}/, t) ->
        t |> binary_part(0, 10) |> Date.from_iso8601() |> ok_date()

      match = Regex.run(~r/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})/, t) ->
        [_, d, m, y] = match
        Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) |> ok_date()

      true ->
        nil
    end
  end

  def date(_), do: nil

  defp ok_date({:ok, date}), do: Date.to_iso8601(date)
  defp ok_date(_), do: nil

  @doc "Term id and label: `{\"2026-1\", \"2026-I\"}`."
  def term(year, number) when is_integer(year) and is_integer(number) do
    roman =
      case number do
        1 -> "I"
        2 -> "II"
        n -> Integer.to_string(n)
      end

    {"#{year}-#{number}", "#{year}-#{roman}"}
  end

  @doc "Modality words as the app shows them."
  def modality(value) do
    case value |> text() |> then(&(&1 && String.upcase(&1))) do
      nil -> nil
      "PRESENCIAL" <> _ -> "in_person"
      "SEMIPRESENCIAL" <> _ -> "blended"
      "SEMI-PRESENCIAL" <> _ -> "blended"
      "A DISTANCIA" <> _ -> "distance"
      "DISTANCIA" <> _ -> "distance"
      "VIRTUAL" <> _ -> "virtual"
      other -> String.downcase(other)
    end
  end

  @campus %{
    "HU" => "Huancayo",
    "HYO" => "Huancayo",
    "LM" => "Lima",
    "LI" => "Lima",
    "CH" => "Chanchamayo",
    "CHA" => "Chanchamayo",
    "ST" => "Satipo",
    "SAT" => "Satipo",
    "TR" => "Tarma",
    "TAR" => "Tarma",
    "CER" => "Cerro de Pasco"
  }

  @doc "Campus name from a code (`HU`) or an upper-case name."
  def campus(value) do
    case text(value) do
      nil -> nil
      t -> Map.get(@campus, String.upcase(t)) || title(t)
    end
  end

  @small ~w(de del la las los y e en a al)

  @doc "`INGENIERÍA DE SISTEMAS` → `Ingeniería de Sistemas`. Keeps roman numerals."
  def title(value) do
    case text(value) do
      nil ->
        nil

      t ->
        t
        |> String.split(~r/\s+/u, trim: true)
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {word, i} ->
          lower = String.downcase(word)

          cond do
            word =~ ~r/^[IVXLC]+$/ and String.length(word) <= 4 -> word
            i > 0 and lower in @small -> lower
            true -> String.capitalize(lower)
          end
        end)
    end
  end

  @doc "Photo URL used by the university for a student code or a DNI."
  def photo_url(code) when is_binary(code) do
    c = String.trim(code)

    if String.length(c) == 7,
      do: "https://academico.upla.edu.pe/FotosAlum/037000#{c}.jpg",
      else: "https://academico.upla.edu.pe/PhotD/#{c}.jpg"
  end

  def photo_url(_), do: nil
end
