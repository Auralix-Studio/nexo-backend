defmodule Nexo.Billing.Payments do
  @moduledoc """
  What the student owes, the term's installment plan and what they paid, all
  from the Intranet's debt page (`consultaEstadoDeuda_Estudiante`).

  Upstream sends one positional row per charge:

    * `consultarPensiones` — installments not yet due:
      `[description, due dd-MM-yyyy, currency, amount, late fee, total, note]`;
    * `consultartotalPensiones` — despite the name, the overdue installments
      in the same shape (the app read it as a total, always 0);
    * `consultarMatricula` — overdue enrollment, `[description, currency,
      amount]`, `["--", "--"]` when none;
    * `consultarReduccionDeuda` — discounts, `[date, description, amount,
      note]` (no non-empty sample seen);
    * `consultarTasas` — fees, `[description, currency, amount, note]`;
    * `consultarUltimasOperaciones` — paid items, one row per item of a bank
      operation, grouped here by serial and number;
    * `consultarCuotasEstudiante` — the term's installment plan.

  The status of each charge is computed from its due date in Lima time, not
  from which endpoint returned it.
  """
  alias Nexo.Academic.Terms
  alias Nexo.Upstream.{Intranet, Normalize, Sessions}

  @referer "consultaEstadoDeuda_Estudiante"
  @currency "PEN"
  @due_soon_days 7

  # --- Debt -------------------------------------------------------------------------------

  @doc "`{:ok, payments, meta}` or `{:error, :reauth_required | :unavailable}`."
  def debt(subject, student, today \\ lima_today()) do
    form = %{"codEst" => to_string(student["code"])}

    result =
      Sessions.with_session(subject, :intranet, fn cookies ->
        Enum.reduce_while(
          ~w(consultarPensiones consultartotalPensiones consultarMatricula consultarReduccionDeuda consultarTasas),
          {:ok, %{}, cookies},
          fn path, {:ok, acc, cookies} ->
            case Intranet.post(cookies, path, form, @referer) do
              {:ok, rows, cookies} -> {:cont, {:ok, Map.put(acc, path, rows(rows)), cookies}}
              error -> {:halt, error}
            end
          end
        )
      end)

    with {:ok, raw} <- result do
      {:ok, build_debt(raw, today), %{source: "intranet"}}
    end
  end

  @doc false
  def build_debt(raw, today) do
    charges =
      (Enum.map(raw["consultarPensiones"], &installment/1) ++
         Enum.map(raw["consultartotalPensiones"], &installment/1) ++
         Enum.map(raw["consultarMatricula"], &enrollment/1) ++
         Enum.map(raw["consultarReduccionDeuda"], &discount/1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&Map.put(&1, :status, status(&1.due_date, today)))
      |> Enum.sort_by(&{&1.due_date || "0000", &1.id})

    {overdue, pending} = Enum.split_with(charges, &(&1.status == "overdue"))
    fees = raw["consultarTasas"] |> Enum.map(&fee/1) |> Enum.reject(&is_nil/1)
    next = Enum.find(pending, &(&1.due_date && &1.total > 0))

    %{
      currency: @currency,
      summary: %{
        pending_total: money(sum(charges)),
        overdue_total: money(sum(overdue)),
        fees_total: money(sum(fees, :amount)),
        next_due: next && %{id: next.id, due_date: next.due_date, total: next.total}
      },
      overdue: overdue,
      pending: pending,
      fees: fees
    }
  end

  defp sum(items, key \\ :total), do: Enum.reduce(items, 0, &(Map.fetch!(&1, key) + &2))

  @doc false
  def installment([description, due, _currency, amount, late_fee, total | rest]) do
    with text when is_binary(text) <- Normalize.text(description) do
      note = rest |> List.first() |> Normalize.text()
      {term, number} = term_and_number(text)
      credits = credit_extension(note)
      amount = money(Normalize.number(amount) || 0.0)
      late_fee = money(Normalize.number(late_fee) || 0.0)

      base = "#{term || "x"}-cuota-#{pad(number)}"

      %{
        id: if(credits, do: base <> "-credits", else: base),
        kind: if(credits, do: "credit_extension", else: "tuition_installment"),
        label: if(credits, do: "Ampliación de créditos", else: "Cuota #{pad(number)}"),
        term: term,
        number: number,
        due_date: Normalize.date(due),
        amount: amount,
        late_fee: late_fee,
        total: money(Normalize.number(total) || amount + late_fee),
        note: credits || note
      }
    end
  end

  def installment(_), do: nil

  defp enrollment([description, _currency, amount | _]) do
    with text when is_binary(text) <- Normalize.text(description),
         value when is_number(value) <- Normalize.number(amount) do
      %{
        id: "enrollment-" <> slug(text),
        kind: "enrollment",
        label: Normalize.title(text),
        term: nil,
        number: nil,
        due_date: nil,
        amount: money(value),
        late_fee: 0.0,
        total: money(value),
        note: nil
      }
    end
  end

  defp enrollment(_), do: nil

  defp discount([date, description, amount | rest]) do
    with value when is_number(value) <- Normalize.number(amount) do
      label = Normalize.title(description) || "Descuento"
      value = -abs(money(value))

      %{
        id: "discount-" <> slug("#{date}-#{label}"),
        kind: "discount",
        label: label,
        term: nil,
        number: nil,
        due_date: Normalize.date(date),
        amount: value,
        late_fee: 0.0,
        total: value,
        note: rest |> List.first() |> Normalize.text()
      }
    end
  end

  defp discount(_), do: nil

  defp fee([description, _currency, amount | rest]) do
    with text when is_binary(text) <- Normalize.text(description),
         value when is_number(value) <- Normalize.number(amount) do
      %{
        label: fee_label(text),
        amount: money(value),
        note: rest |> List.first() |> Normalize.text()
      }
    end
  end

  defp fee(_), do: nil

  # "SEGURO UNIVERSITARIO POLICLINICO UPLA 261" → "Seguro Universitario Policlinico UPLA 261"
  defp fee_label(text) do
    text |> Normalize.title() |> String.replace(~r/\bUpla\b/, "UPLA")
  end

  # "CUOTA 03 Periodo 2026-1" → {"2026-1", 3}
  defp term_and_number(text) do
    number =
      case Regex.run(~r/cuota\s*0*(\d+)/i, text) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end

    term =
      case Regex.run(~r/(\d{4})\s*-\s*(\d)/, text) do
        [_, y, n] -> "#{y}-#{n}"
        _ -> nil
      end

    {term, number}
  end

  # "AMP. CRED. 4 cred, 31.00 S/ cada cred PROV. No." → "4 créditos × S/ 31.00"
  defp credit_extension(nil), do: nil

  defp credit_extension(note) do
    if note =~ ~r/AMP\.?\s*CRED/i do
      case Regex.run(~r/(\d+)\s*cred[^\d]*([\d.]+)/i, note) do
        [_, count, price] ->
          "#{count} créditos × S/ #{:erlang.float_to_binary(money(Normalize.number(price)), decimals: 2)}"

        _ ->
          "Ampliación de créditos"
      end
    end
  end

  defp pad(nil), do: "00"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc "`pending | due_soon | overdue` for a due date (ISO) and today in Lima."
  def status(nil, _today), do: "overdue"

  def status(due, today) do
    case Date.from_iso8601(due) do
      {:ok, date} ->
        days = Date.diff(date, today)

        cond do
          days < 0 -> "overdue"
          days <= @due_soon_days -> "due_soon"
          true -> "pending"
        end

      _ ->
        "pending"
    end
  end

  # --- Installment plan ---------------------------------------------------------------

  @doc "`{:ok, schedule, meta}` or an error."
  def schedule(subject) do
    result =
      Sessions.with_session(subject, :intranet, fn cookies ->
        with {:ok, rows, cookies} <-
               Intranet.get(
                 cookies,
                 "consultarCuotasEstudiante?installments=30",
                 "pg_reportesDelEstudiante"
               ) do
          {:ok, rows, cookies}
        end
      end)

    with {:ok, rows} <- result do
      term =
        case Terms.resolve(subject, nil) do
          {:ok, t} -> %{id: t.id, label: t.label}
          _ -> nil
        end

      {:ok, build_schedule(rows(rows), term), %{source: "intranet"}}
    end
  end

  @doc false
  def build_schedule(rows, term) do
    installments =
      for [_, _, amount, number, due | _] <- rows,
          n = Normalize.int(number),
          is_integer(n),
          do: %{number: n, amount: money(Normalize.number(amount)), due_date: Normalize.date(due)}

    first = List.first(rows) || []

    %{
      term: term,
      currency: @currency,
      term_total: first |> Enum.at(1) |> Normalize.number() |> money(),
      installments: Enum.sort_by(installments, & &1.number),
      generated_at: first |> Enum.at(6) |> datetime()
    }
  end

  # --- History ------------------------------------------------------------------------

  @doc "`{:ok, history, meta}` or an error."
  def history(subject, student) do
    form = %{"codEst" => to_string(student["code"])}

    result =
      Sessions.with_session(subject, :intranet, fn cookies ->
        with {:ok, rows, cookies} <-
               Intranet.post(cookies, "consultarUltimasOperaciones", form, @referer) do
          {:ok, rows, cookies}
        end
      end)

    with {:ok, rows} <- result do
      {:ok, %{currency: @currency, operations: build_history(rows(rows))}, %{source: "intranet"}}
    end
  end

  @doc false
  def build_history(rows) do
    rows
    |> Enum.filter(&(length(&1) >= 9))
    |> Enum.group_by(fn [serial, number | _] ->
      {Normalize.text(serial), Normalize.text(number)}
    end)
    |> Enum.map(fn {{serial, number}, [first | _] = items} ->
      at = &Normalize.text(Enum.at(first, &1))

      items =
        items
        |> Enum.sort_by(&Normalize.int(Enum.at(&1, 3)))
        |> Enum.map(fn r ->
          concept = Normalize.text(Enum.at(r, 6))
          amount = money(Normalize.number(Enum.at(r, 8)))

          %{
            concept: concept_label(concept),
            kind: item_kind(concept, amount),
            amount: amount,
            voucher: Normalize.text(Enum.at(r, 10))
          }
        end)

      %{
        id: Enum.join(Enum.reject([serial, number], &is_nil/1), "-"),
        date: Normalize.date(Enum.at(first, 4)),
        term: at.(5),
        place: place(at.(11)),
        voucher: Enum.find_value(items, & &1.voucher),
        bank_reference: at.(9),
        total: money(Enum.reduce(items, 0, &(&1.amount + &2))),
        items: items
      }
    end)
    |> Enum.sort_by(&{&1.date || "", &1.id}, :desc)
  end

  defp item_kind(concept, amount) do
    c = String.downcase(concept || "")

    cond do
      amount < 0 or c =~ "dsct" or c =~ "descuento" -> "discount"
      c =~ "mora" or c =~ "recargo" -> "late_fee"
      true -> "payment"
    end
  end

  defp concept_label(nil), do: nil

  defp concept_label(concept) do
    concept
    |> Normalize.title()
    |> String.replace(~r/\bHyo\b/, "Huancayo")
  end

  defp place(nil), do: nil

  defp place(text) do
    text
    |> Normalize.title()
    |> String.replace(~r/\bHyo\b/, "Huancayo")
    |> String.replace(~r/\bUpla\b/, "UPLA")
  end

  # --- Shared ---------------------------------------------------------------------------

  # Rows that hold data: lists, without `No hay datos` or `--` placeholders.
  defp rows(rows) do
    for r <- rows, is_list(r), r != [], Normalize.text(hd(r)) != nil, do: r
  end

  defp money(nil), do: nil
  defp money(n), do: Float.round(n * 1.0, 2)

  defp lima_today do
    DateTime.utc_now() |> DateTime.add(-5 * 3600) |> DateTime.to_date()
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc "`Mar 31 2026 05:34:33:537PM` → `2026-03-31T17:34:33-05:00`; `nil` otherwise."
  def datetime(value) do
    with t when is_binary(t) <- Normalize.text(value),
         [_, mon, day, year, h, m, s, ampm] <-
           Regex.run(
             ~r/^([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})(?::\d+)?\s*([AP]M)$/i,
             t
           ),
         month when is_integer(month) <-
           Enum.find_index(@months, &(&1 == String.downcase(mon))) do
      hour = rem(String.to_integer(h), 12) + if(String.upcase(ampm) == "PM", do: 12, else: 0)
      two = &String.pad_leading(to_string(&1), 2, "0")

      "#{year}-#{two.(month + 1)}-#{two.(day)}T#{two.(hour)}:#{m}:#{s}-05:00"
    else
      _ -> nil
    end
  end
end
