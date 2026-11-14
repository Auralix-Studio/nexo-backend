defmodule Nexo.Schedule.Days do
  @moduledoc "Weekday and time helpers shared by schedule sources."

  @names ~w(Lunes Martes Miércoles Jueves Viernes Sábado Domingo)
  @tokens %{"LU" => 1, "MA" => 2, "MI" => 3, "JU" => 4, "VI" => 5, "SA" => 6, "DO" => 7}

  @doc "Spanish day name for an ISO weekday (1 = Monday)."
  def name(weekday) when weekday in 1..7, do: Enum.at(@names, weekday - 1)
  def name(_), do: nil

  @doc "`\"LU-MA-MI\"` → `[1, 2, 3]`; unknown tokens are skipped."
  def parse_tokens(value) when is_binary(value) do
    value
    |> String.split(~r/[-,\s]+/, trim: true)
    |> Enum.map(&Map.get(@tokens, String.upcase(&1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def parse_tokens(_), do: []

  @doc "`\"8:00:00\"` → `\"08:00\"`; `nil` when it is not a time."
  def hhmm(value) when is_binary(value) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})/, String.trim(value)) do
      [_, h, m] -> if String.to_integer(h) < 24, do: String.pad_leading(h, 2, "0") <> ":" <> m
      _ -> nil
    end
  end

  def hhmm(_), do: nil

  @doc "Minutes since midnight of an `HH:MM` string."
  def minutes(<<h::binary-2, ":", m::binary-2>>),
    do: String.to_integer(h) * 60 + String.to_integer(m)
end
