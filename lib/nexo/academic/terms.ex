defmodule Nexo.Academic.Terms do
  @moduledoc """
  The student's academic terms, merged from SIGMA and the Intranet.

  SIGMA lists terms newest first and says which one is active; the Intranet
  lists them oldest first and says nothing (the app used to assume its last
  row). Labels differ too (`"2026 - 1"`, `"2025 - II"`). The result is one
  list, newest first, with ids like `"2026-1"` and labels like `"2026-I"`.
  """
  alias Nexo.Infra.Cache
  alias Nexo.Upstream.{Normalize, Sessions}

  # Terms change once a semester; most routes resolve one first.
  @ttl :timer.hours(6)

  @type term_info :: %{
          id: String.t(),
          year: integer(),
          number: integer(),
          label: String.t(),
          active: boolean()
        }

  @doc """
  Terms plus the status of each source. `{:error, :reauth_required}` if none
  answered. Cached #{div(@ttl, 3_600_000)} h per user when both sources answered.
  """
  def list(subject) do
    Cache.subject(subject, :terms, fn -> fetch(subject) end,
      ttl: @ttl,
      cache_if: &Cache.sources_ok?/1
    )
  end

  defp fetch(subject) do
    sigma = from_sigma(subject)
    intranet = from_intranet(subject)

    case {sigma, intranet} do
      {{:error, :reauth_required}, {:error, :reauth_required}} ->
        {:error, :reauth_required}

      _ ->
        {:ok, merge(rows(sigma), rows(intranet)),
         %{sigma: Sessions.status(sigma), intranet: Sessions.status(intranet)}}
    end
  end

  @doc "The active term, or the newest one."
  def active(terms), do: Enum.find(terms, & &1.active) || List.first(terms)

  @doc "The term with `term_id` (or the active one when `nil`): `{:ok, term}` or an error."
  def resolve(subject, term_id) do
    case list(subject) do
      {:ok, terms, _} ->
        term = if term_id, do: Enum.find(terms, &(&1.id == term_id)), else: active(terms)
        if term, do: {:ok, term}, else: {:error, :unknown_term}

      {:error, _} = error ->
        error
    end
  end

  defp from_sigma(subject) do
    with {:ok, data} <- Sessions.sigma_fetch(subject, "/Recursos/ListarPeriodosEstudiante") do
      rows =
        for row <- List.wrap(data),
            is_map(row),
            year = Normalize.int(row["anio"]),
            number = Normalize.int(row["periodo"]),
            is_integer(year) and is_integer(number),
            do: %{year: year, number: number, active: Normalize.bool(row["activo"])}

      {:ok, rows}
    end
  end

  defp from_intranet(subject) do
    with {:ok, data} <-
           Sessions.intranet_post(subject, "consultarPeriodosMatriculados", %{}, "inicio") do
      rows =
        for [y, n | _] <- data,
            year = Normalize.int(y),
            number = Normalize.int(n),
            is_integer(year) and is_integer(number),
            do: %{year: year, number: number, active: false}

      {:ok, rows}
    end
  end

  defp rows({:ok, rows}), do: rows
  defp rows(_), do: []

  @doc false
  def merge(sigma_rows, intranet_rows) do
    by_key =
      (intranet_rows ++ sigma_rows)
      |> Enum.reduce(%{}, fn row, acc ->
        Map.update(acc, {row.year, row.number}, row, &%{&1 | active: &1.active or row.active})
      end)

    sorted =
      by_key
      |> Map.values()
      |> Enum.sort_by(&{&1.year, &1.number}, :desc)

    # Only SIGMA knows the active term; without it, the newest one is.
    sorted =
      if Enum.any?(sorted, & &1.active) do
        sorted
      else
        case sorted do
          [newest | rest] -> [%{newest | active: true} | rest]
          [] -> []
        end
      end

    Enum.map(sorted, fn row ->
      {id, label} = Normalize.term(row.year, row.number)
      %{id: id, year: row.year, number: row.number, label: label, active: row.active}
    end)
  end
end
