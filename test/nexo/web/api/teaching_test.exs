defmodule Nexo.Web.Api.TeachingTest do
  @moduledoc "Module 5 of the Nexo API: the teacher's sections, grades, attendance and own punches."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Cache, RateLimiter}
  alias Nexo.People.Teachers
  alias Nexo.Teaching.{Attendance, Presence, Sections}

  setup do
    RateLimiter.reset()

    # The section list is cached per teacher; each test starts cold.
    case Teachers.get_teacher_by_code("D001") do
      %{"_id" => id} ->
        Cache.invalidate_subject(%{type: :teacher, id: Nexo.Infra.Db.id_to_string(id)})

      _ ->
        :ok
    end

    :ok
  end

  defp sections(conn), do: conn |> get("/teaching/sections") |> json_response(200)

  defp section_id(conn) do
    conn |> sections() |> get_in(["data", Access.at(0), "id"])
  end

  describe "GET /teaching/sections" do
    test "both SIGMA lists merged, duplicates dropped, upstream ids hidden", %{conn: conn} do
      conn = logged_in(conn)
      [db, iot] = sections(conn)["data"]

      assert db["id"] =~ ~r/^sec_[0-9a-f]{16}$/
      assert db["id"] != iot["id"]
      assert db["course"] == %{"code" => "341119", "name" => "Base de Datos I"}
      assert {db["term"], db["nrc"], db["section"]} == {"2026-2", "341119", "A2"}
      assert db["career"] == "Ingenieria de Sistemas"
      assert db["modality"] == "in_person"
      assert {db["cycle"], db["enrolled"], db["elective"]} == {4, 2, false}
      assert db["campus"] == "Huancayo"
      assert db["room"] == %{"building" => "Pabellón K", "name" => "K 101", "capacity" => 40}

      assert db["schedule"] == [
               %{"weekday" => 2, "start" => "16:45", "end" => "19:00", "kind" => "theory"},
               %{"weekday" => 4, "start" => "11:30", "end" => "13:00", "kind" => "practice"}
             ]

      refute Map.has_key?(db, "upstream")
      assert iot["elective"]
      assert iot["course"]["name"] == "Internet de las Cosas"
    end

    test "students cannot reach teacher routes", %{conn: conn} do
      conn = conn |> logged_in("E001") |> get("/teaching/sections")
      assert conn.status in [401, 403]
    end

    test "an expired SIGMA session asks to log in again", %{conn: conn} do
      conn = conn |> logged_in("D001", "expirado") |> get("/teaching/sections")
      assert json_response(conn, 401)["error"]["code"] == "reauth_required"
    end

    test "another teacher's or unknown section is a 404", %{conn: conn} do
      conn = conn |> logged_in() |> get("/teaching/sections/sec_0000000000000000/students")
      assert json_response(conn, 404)["error"]["code"] == "unknown_section"
    end
  end

  test "GET roster: units by type, null final grade without grades", %{conn: conn} do
    conn = logged_in(conn)
    id = section_id(conn)
    body = conn |> get("/teaching/sections/#{id}/students") |> json_response(200)
    [ana, luis] = body["data"]["students"]

    assert body["data"]["section_id"] == id
    assert {ana["code"], ana["name"]} == {"U001", "Rojas Quispe Ana"}
    assert {ana["attendance_percent"], ana["at_risk"], ana["suspended"]} == {82.5, false, false}
    assert ana["final_grade"] == 13.0
    [unit] = ana["units"]
    assert {unit["unit_id"], unit["name"], unit["weight_percent"]} == {101, "Unidad 1", 25.0}

    assert Enum.map(unit["evaluations"], &{&1["abbr"], &1["type"], &1["grades"]}) == [
             {"EV", "knowledge", [15.0]},
             {"DE", "performance", [14.0]}
           ]

    refute Map.has_key?(ana, "matricula_asignatura_id")
    assert {luis["final_grade"], luis["at_risk"], luis["suspended"]} == {nil, true, true}
  end

  test "GET grade-units: open flag and types with scale", %{conn: conn} do
    conn = logged_in(conn)
    id = section_id(conn)

    [u1, u2] =
      conn |> get("/teaching/sections/#{id}/grade-units") |> json_response(200) |> Map.get("data")

    assert {u1["unit_id"], u1["name"], u1["open"]} == {101, "Unidad 1", true}

    assert u1["types"] == [
             %{
               "type_id" => 11,
               "abbr" => "EV",
               "name" => "Evidencia de Conocimiento",
               "max" => 20.0,
               "passing" => 10.5,
               "max_columns" => 2,
               "color" => "#4F46E5"
             }
           ]

    assert {u2["open"], u2["types"]} == {false, []}
  end

  describe "PUT grades" do
    test "update, insert and per-student failures", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      body =
        conn
        |> put("/teaching/sections/#{id}/grades", %{
          "unit_id" => 101,
          "type_id" => 11,
          "grades" => [
            %{"student" => "U001", "value" => 16, "column" => 0},
            %{"student" => "U002", "value" => 12},
            %{"student" => "U999", "value" => 10}
          ]
        })
        |> json_response(200)

      assert body["data"] == %{
               "saved" => 2,
               "unchanged" => 0,
               "failed" => [%{"student" => "U999", "reason" => "not_in_section"}]
             }

      assert_received {:sigma_post, "/Docente/InsertarNotas", _,
                       %{"Notas" => [%{"matricula_asignatura_id" => "M2", "nota" => 12.0} = ins]}}

      assert {ins["tipo_unidad_id"], ins["tipo_nota_id"]} == {101, 11}

      assert_received {:sigma_post, "/Docente/UpdateNota", _,
                       %{
                         "Notas" => [
                           %{"matricula_asignatura_id" => "M1", "nota_id" => 500, "nota" => 16.0}
                         ]
                       }}
    end

    test "unchanged values, range and columns are checked", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      body =
        conn
        |> put("/teaching/sections/#{id}/grades", %{
          "unit_id" => 101,
          "type_id" => 11,
          "column" => 0,
          "grades" => [
            %{"student" => "U001", "value" => 15},
            %{"student" => "U002", "value" => 25},
            %{"student" => "U002", "value" => 12, "column" => 1}
          ]
        })
        |> json_response(200)

      assert body["data"]["saved"] == 0
      assert body["data"]["unchanged"] == 1

      assert body["data"]["failed"] == [
               %{"student" => "U002", "reason" => "invalid_value"},
               %{"student" => "U002", "reason" => "column_gap"}
             ]

      refute_received {:sigma_post, _, _, _}
    end

    test "closed unit and unknown type", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      closed =
        conn
        |> put("/teaching/sections/#{id}/grades", %{
          "unit_id" => 102,
          "type_id" => 11,
          "grades" => [%{"student" => "U001", "value" => 15}]
        })

      # Unit 102 has no grade types, so the type is unknown before it is closed.
      assert json_response(closed, 422)["error"]["code"] == "unknown_grade_type"

      unknown =
        conn
        |> put("/teaching/sections/#{id}/grades", %{
          "unit_id" => 999,
          "type_id" => 11,
          "grades" => []
        })

      assert json_response(unknown, 422)["error"]["code"] == "unknown_unit"
    end
  end

  describe "attendance" do
    test "GET sheet: sessions by timestamp, states as words, hidden units dropped", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      data =
        conn
        |> get("/teaching/sections/#{id}/attendance")
        |> json_response(200)
        |> Map.get("data")

      assert data["units"] == [%{"unit_id" => 201, "name" => "Unidad 2", "open" => true}]
      assert data["server_time"] == "2026-11-05T09:05:07-05:00"

      assert data["sessions"] == [
               %{
                 "id" => "2026-10-29T14:41:00",
                 "taken_at" => "2026-10-29T14:41:00-05:00",
                 "unit_id" => 201,
                 "present" => 1,
                 "absent" => 0,
                 "justified" => 0
               }
             ]

      [ana, luis] = data["students"]
      assert ana["marks"] == [%{"session" => "2026-10-29T14:41:00", "state" => "present"}]
      assert {luis["suspended"], hd(luis["marks"])["state"]} == {true, "suspended"}
    end

    test "POST: SIGMA's clock and format, suspended always suspended", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      body =
        conn
        |> post("/teaching/sections/#{id}/attendance", %{
          "unit_id" => 201,
          "marks" => [
            %{"student" => "U001", "state" => "present"},
            %{"student" => "U002", "state" => "present"},
            %{"student" => "U001", "state" => "late"}
          ]
        })
        |> json_response(200)

      assert body["data"] == %{
               "session" => "2026-11-05T09:05:07",
               "saved" => 2,
               "failed" => [%{"student" => "U001", "reason" => "invalid_state"}]
             }

      assert_received {:sigma_post, "/Docente/InsertaRegistroAsistencia", _, sent}
      assert sent["fecha_asistencia"] == "2026-11-05 9:5:7"

      assert sent["asistencia"] == [
               %{
                 "matricula_asignatura_id" => "M1",
                 "estado_asist_id" => 1,
                 "cod_cursal" => "419329",
                 "tipo_unidad_id" => 201
               },
               %{
                 "matricula_asignatura_id" => "M2",
                 "estado_asist_id" => 4,
                 "cod_cursal" => "419329",
                 "tipo_unidad_id" => 201
               }
             ]
    end

    test "PATCH: marks found by session timestamp", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)

      body =
        conn
        |> patch("/teaching/sections/#{id}/attendance/2026-10-29T14:41:00", %{
          "marks" => [%{"student" => "U001", "state" => "justified"}]
        })
        |> json_response(200)

      assert body["data"] == %{"saved" => 1, "failed" => []}

      assert_received {:sigma_post, "/Docente/ActualizarRegistroAsistencia", _,
                       %{
                         "asistencia" => [
                           %{
                             "asistencia_id" => 7001,
                             "matricula_asignatura_id" => "M1",
                             "estado_asist_id" => 3
                           }
                         ]
                       }}
    end

    test "an unpadded upstream time is one session id" do
      assert Attendance.session_id("2026-10-29 9:5:0") == "2026-10-29T09:05:00"
      assert Attendance.session_id("x") == nil
    end
  end

  describe "own attendance" do
    test "GET virtual classes and POST punch", %{conn: conn} do
      conn = logged_in(conn)
      [class] = conn |> get("/teaching/virtual-classes") |> json_response(200) |> Map.get("data")

      assert class == %{
               "id" => "C123",
               "course" => "Base de Datos I",
               "section" => "A2",
               "career" => "Sistemas",
               "start" => "08:00",
               "end" => "09:45",
               "tolerance" => %{"before_minutes" => 10, "after_minutes" => 15},
               "checked_in_at" => "07:58",
               "checked_out_at" => nil,
               "can_check_in" => false,
               "can_check_out" => true
             }

      body = conn |> post("/teaching/virtual-classes/C123/punch") |> json_response(200)
      assert body["data"] == %{"result" => "success", "message" => "Salida registrada"}

      assert_received {:sigma_post, "/Docente/InsertaRegistroAsistenciaDocente",
                       %{"codigo" => "C123"}, nil}

      missing = conn |> post("/teaching/virtual-classes/NOPE/punch")
      assert json_response(missing, 404)["error"]["code"] == "unknown_class"
    end

    test "GET punches and compliance (pages walked, repeats dropped)", %{conn: conn} do
      conn = logged_in(conn)

      [punch] =
        conn
        |> get("/teaching/punches", %{"from" => "2026-10-01", "to" => "2026-10-31"})
        |> json_response(200)
        |> Map.get("data")

      assert punch == %{
               "date" => "2026-10-07",
               "time" => "07:58",
               "weekday" => 3,
               "mode" => "Entrada",
               "location" => "VIRTUAL",
               "virtual" => true
             }

      [day] = conn |> get("/teaching/compliance") |> json_response(200) |> Map.get("data")

      assert {day["date"], day["check_in"], day["check_out"]} ==
               {"2026-10-07", "marked", "missing"}

      assert {day["course"], day["modality"]} == {"Base de Datos I", "in_person"}
    end

    test "SIGMA messages" do
      assert Presence.sigma_message("I - Ya marcó") == %{result: "info", message: "Ya marcó"}
      assert Presence.sigma_message(nil) == %{result: "success", message: nil}
    end
  end

  test "schedule text with ids by day in Sunday-first order" do
    [tue, thu] = Sections.blocks("Jueves 11:30:00 13:00:00 P, Martes 16:45:00 19:00:00 T", "1, 2")
    assert {tue.weekday, tue.cod_cursal, thu.cod_cursal} == {2, "1", "2"}
  end
end
