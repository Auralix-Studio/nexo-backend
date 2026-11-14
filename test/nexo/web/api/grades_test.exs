defmodule Nexo.Web.Api.GradesTest do
  @moduledoc "Module 3 of the Nexo API: term grades, course detail, summary and curriculum."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Academic.Grades
  alias Nexo.Infra.RateLimiter

  setup do
    RateLimiter.reset()

    wipe(~w(students refresh_tokens upstream_sessions))

    :ok
  end

  describe "GET /grades (competencies)" do
    test "current grade from the units, official as shown, 0–100 workshops on 0–20", %{
      conn: conn
    } do
      body =
        conn |> logged_in("E001") |> get("/grades", %{"term" => "2026-1"}) |> json_response(200)

      data = body["data"]

      assert data["term"] == %{"id" => "2026-1", "label" => "2026-I"}
      assert data["model"] == "competencies"
      assert data["scale"] == %{"max" => 20, "passing" => 10.5}

      [db, workshop, networks] = data["courses"]

      assert db["id"] == "IS-301"
      assert db["name"] == "Base de Datos"
      assert {db["cycle"], db["credits"], db["attendance_percent"]} == {7, 3, 95}
      assert db["status"] == "in_progress"
      refute db["closed"]
      # 14 (40 %) and 15 (60 %) on the only graded unit; upstream showed 2.9 → 3.
      assert db["grade"] == %{"current" => 14.6, "official" => 3}
      assert length(db["units"]) == 3
      refute Map.has_key?(db, "upstream_id")

      assert workshop["grade"] == %{"current" => 17, "official" => 17}
      assert workshop["status"] == "passed"
      assert workshop["closed"]

      assert networks["grade"] == %{"current" => 9.4, "official" => 9}
      assert networks["status"] == "failed"

      assert data["average"] == %{"value" => 12.3, "official" => 7.75, "credits" => 8}
      assert body["meta"]["source"] == "intranet"
    end

    test "the active term is the default", %{conn: conn} do
      body = conn |> logged_in("E001") |> get("/grades") |> json_response(200)
      assert body["data"]["term"]["id"] == "2026-2"
    end

    test "an unknown term is a 404", %{conn: conn} do
      conn = conn |> logged_in("E001") |> get("/grades", %{"term" => "1999-1"})
      assert json_response(conn, 404)["error"]["code"] == "unknown_term"
    end
  end

  describe "GET /grades (legacy)" do
    test "the 50-column Intranet rows become the same shape", %{conn: conn} do
      body =
        conn |> logged_in("E001") |> get("/grades", %{"term" => "2025-2"}) |> json_response(200)

      assert body["data"]["model"] == "legacy"
      [course] = body["data"]["courses"]

      assert course["code"] == "IS-201"
      assert course["name"] == "Estructura de Datos"
      assert {course["cycle"], course["credits"]} == {5, 4}
      assert course["type"] == "mandatory"
      # Intranet closes with "1", not "True".
      assert course["closed"]
      assert course["status"] == "passed"
      assert course["grade"] == %{"current" => 15, "official" => 15}
      assert course["makeup_exam"] == nil
      assert course["rank"] == %{"position" => 3, "of" => 40}

      [first, second] = course["units"]
      assert first["average"] == 14
      assert first["practices_average"] == 14

      assert Enum.map(first["evidences"], &{&1["type"], &1["grade"]}) == [
               {"practice", 15},
               {"practice", 13},
               {"individual_work", 16},
               {"partial_exam", 13}
             ]

      assert Enum.map(second["evidences"], & &1["type"]) == ["practice", "partial_exam"]
    end

    test "falls back to SIGMA, make-up exam included", %{conn: conn} do
      body =
        conn |> logged_in("E004") |> get("/grades", %{"term" => "2025-2"}) |> json_response(200)

      [course] = body["data"]["courses"]

      assert course["grade"] == %{"current" => 11, "official" => 11}
      assert course["makeup_exam"] == 12
      assert course["status"] == "passed"
      assert course["rank"] == nil
      assert body["meta"]["source"] == "sigma"
    end
  end

  describe "GET /grades/:term/courses/:id" do
    test "units, evidences and what the pending units need", %{conn: conn} do
      body =
        conn
        |> logged_in("E001")
        |> get("/grades/2026-1/courses/IS-301")
        |> json_response(200)

      data = body["data"]

      assert data["course"] == %{
               "id" => "IS-301",
               "code" => "IS-301",
               "name" => "Base de Datos",
               "credits" => 3
             }

      [u1, u2, u3] = data["units"]

      assert {u1["number"], u1["name"], u1["weight_percent"], u1["average"]} ==
               {1, "Unidad 1", 20, 14.6}

      assert Enum.map(
               u1["evidences"],
               &{&1["type"], &1["label"], &1["weight_percent"], &1["grade"]}
             ) ==
               [
                 {"knowledge", "Evidencia de Conocimiento", 40, 14},
                 {"performance", "Evidencia de Desempeño", 60, 15}
               ]

      # Zeros in an in-progress course are "not graded yet".
      assert u2["average"] == nil
      assert hd(u2["evidences"])["grade"] == nil
      assert u3["average"] == nil

      assert data["makeup_exam"] == nil
      assert data["final"] == %{"current" => 14.6, "official" => 3, "status" => "in_progress"}

      # (10.5 × 100 − 14.6 × 20) / 80
      assert %{"status" => "reachable", "target" => 10.5, "needed_average" => needed} =
               data["projection"]

      assert_in_delta needed, 9.475, 0.01
    end

    test "a closed course has no projection to make", %{conn: conn} do
      body =
        conn
        |> logged_in("E001")
        |> get("/grades/2025-2/courses/IS-201")
        |> json_response(200)

      assert body["data"]["projection"]["status"] == "closed"
      assert length(body["data"]["units"]) == 2
    end

    test "an unknown course is a 404", %{conn: conn} do
      conn = conn |> logged_in("E001") |> get("/grades/2026-1/courses/NOPE")
      assert json_response(conn, 404)["error"]["code"] == "unknown_course"
    end
  end

  test "GET /grades/summary", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/grades/summary") |> json_response(200)
    data = body["data"]

    assert data["cumulative_average"] == 14.12
    assert data["credits"] == %{"approved" => 168, "required" => 220}
    # Newest first; SIGMA's "0" for the running term is no average.
    assert data["terms"] == [
             %{"term" => "2026-1", "average" => 13.8},
             %{"term" => "2025-2", "average" => 14.4}
           ]

    assert data["current_term"] == %{
             "term" => "2026-2",
             "partial_average" => 12.3,
             "passed" => 1,
             "failed" => 1,
             "pending" => 1
           }
  end

  test "GET /curriculum reads cycle and credits from the right columns", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/curriculum") |> json_response(200)
    data = body["data"]

    assert data["plan"] == "2015"
    assert data["career"] == "Ingeniería de Sistemas y Computación"

    assert data["progress"] == %{
             "completed_courses" => 1,
             "pending_courses" => 1,
             "credits_completed" => 3,
             "credits_total" => 7
           }

    [intro, thesis] = data["courses"]

    assert intro == %{
             "code" => "IS-101",
             "name" => "Introduccion a la Ingenieria",
             "cycle" => 1,
             "credits" => 3,
             "type" => "mandatory",
             "status" => "completed",
             "grade" => 15,
             "attempts" => 1
           }

    assert {thesis["cycle"], thesis["credits"], thesis["status"], thesis["grade"]} ==
             {9, 4, "pending", nil}
  end

  describe "projection" do
    test "already passed, impossible and no data" do
      unit = &%{average: &1, weight_percent: &2}

      assert Grades.projection([unit.(20, 60), unit.(nil, 40)], false).status == "already_passed"
      assert Grades.projection([unit.(2, 60), unit.(nil, 40)], false).status == "impossible"
      assert Grades.projection([unit.(nil, 50), unit.(nil, 50)], false).status == "no_data"
      assert Grades.projection([unit.(9, 50), unit.(10, 50)], false).status == "impossible"
    end
  end
end
