defmodule Nexo.Web.Api.PaymentsTest do
  @moduledoc "Module 4 of the Nexo API: debt, installment plan and payment history."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Billing.Payments
  alias Nexo.Infra.RateLimiter

  setup do
    RateLimiter.reset()

    wipe(~w(students refresh_tokens upstream_sessions))

    :ok
  end

  @raw %{
    "consultarPensiones" => [
      ["CUOTA 03 Periodo 2026-1", "12-06-2026", "S/.", "522.5", "0", "522.5", "--"],
      [
        "CUOTA 03 Periodo 2026-1",
        "13-06-2026",
        "S/.",
        "124",
        "0",
        "124",
        "AMP. CRED. 4 cred, 31.00 S/ cada cred PROV. No."
      ],
      ["CUOTA 04 Periodo 2026-1", "06-07-2026", "S/.", "522.5", "0", "522.5", "--"]
    ],
    "consultartotalPensiones" => [
      ["CUOTA 02 Periodo 2026-1", "21-05-2026", "S/.", "124", "0.22", "124.22", "AMP. CRED."]
    ],
    "consultarMatricula" => [["MATRICULA 2026-1", "S/.", "150"]],
    "consultarReduccionDeuda" => [],
    "consultarTasas" => [["SEGURO UNIVERSITARIO POLICLINICO UPLA 261", "S/.", "20", "--"]]
  }

  describe "debt" do
    test "statuses from the due date in Lima, overdue debt counted in the total" do
      debt = Payments.build_debt(@raw, ~D[2026-06-08])

      assert Enum.map(debt.overdue, &{&1.id, &1.kind}) == [
               {"enrollment-matricula-2026-1", "enrollment"},
               {"2026-1-cuota-02-credits", "credit_extension"}
             ]

      assert Enum.map(debt.pending, &{&1.id, &1.status}) == [
               {"2026-1-cuota-03", "due_soon"},
               {"2026-1-cuota-03-credits", "due_soon"},
               {"2026-1-cuota-04", "pending"}
             ]

      [cuota3, credits | _] = debt.pending
      assert cuota3.label == "Cuota 03"
      assert {cuota3.term, cuota3.number, cuota3.due_date} == {"2026-1", 3, "2026-06-12"}
      assert cuota3.note == nil
      assert credits.label == "Ampliación de créditos"
      assert credits.note == "4 créditos × S/ 31.00"

      overdue_credits = Enum.at(debt.overdue, 1)
      assert {overdue_credits.late_fee, overdue_credits.total} == {0.22, 124.22}

      assert debt.summary == %{
               pending_total: 1443.22,
               overdue_total: 274.22,
               fees_total: 20.0,
               next_due: %{id: "2026-1-cuota-03", due_date: "2026-06-12", total: 522.5}
             }

      assert debt.fees == [
               %{label: "Seguro Universitario Policlinico UPLA 261", amount: 20.0, note: nil}
             ]
    end

    test "GET /payments reads the debt page", %{conn: conn} do
      body = conn |> logged_in("E001") |> get("/payments") |> json_response(200)
      data = body["data"]

      assert data["currency"] == "PEN"
      ids = Enum.map(data["overdue"] ++ data["pending"], & &1["id"])

      assert Enum.sort(ids) ==
               ~w(2026-1-cuota-02-credits 2026-1-cuota-03 2026-1-cuota-03-credits)

      # No enrollment debt: the "--" row is not a charge.
      refute Enum.any?(data["overdue"], &(&1["kind"] == "enrollment"))
      assert data["summary"]["pending_total"] == 770.72
      assert body["meta"]["source"] == "intranet"
    end
  end

  test "GET /payments/schedule", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/payments/schedule") |> json_response(200)
    data = body["data"]

    assert data["term"] == %{"id" => "2026-2", "label" => "2026-II"}
    assert data["term_total"] == 2750.0
    assert data["generated_at"] == "2026-03-31T17:34:33-05:00"

    assert data["installments"] == [
             %{"number" => 1, "amount" => 550.0, "due_date" => "2026-04-28"},
             %{"number" => 2, "amount" => 550.0, "due_date" => "2026-05-20"}
           ]
  end

  test "GET /payments/history groups the rows of one operation", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/payments/history") |> json_response(200)
    [a, b, c] = body["data"]["operations"]

    assert {a["id"], b["id"], c["id"]} ==
             {"0002-002368017", "0002-002368016", "0002-002364467"}

    assert a["date"] == "2026-05-20"
    assert a["place"] == "Caja Huancayo"
    assert a["bank_reference"] == "CMAC AG. 000076 OP. 569674"
    assert a["total"] == 522.5

    assert Enum.map(a["items"], &{&1["kind"], &1["amount"]}) == [
             {"payment", 550.0},
             {"discount", -27.5}
           ]

    # Items keep upstream order even when the rows arrive shuffled.
    assert Enum.map(b["items"], & &1["kind"]) == ["payment", "late_fee"]
    assert b["total"] == 124.29
    assert c["date"] == "2026-04-27"
  end

  test "upstream datetime" do
    assert Payments.datetime("Mar 31 2026 05:34:33:537PM") == "2026-03-31T17:34:33-05:00"
    assert Payments.datetime("Jan 2 2026 12:05:00:000AM") == "2026-01-02T00:05:00-05:00"
    assert Payments.datetime("x") == nil
  end
end
