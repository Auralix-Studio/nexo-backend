defmodule Nexo.Web.Api.ScheduleTest do
  @moduledoc "Module 2 of the Nexo API: weekly schedule and Language Center courses."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Academic.Schedule
  alias Nexo.Infra.{Db, RateLimiter}
  alias Nexo.Schedule.Days

  setup do
    RateLimiter.reset()

    for c <- ~w(students refresh_tokens upstream_sessions) do
      Mongo.delete_many(Db.conn(), c, %{})
    end

    :ok
  end

  defp logged_in(conn, user) do
    body =
      conn
      |> post("/auth/login", %{"user" => user, "password" => "ok"})
      |> json_response(200)

    put_req_header(conn, "authorization", "Bearer " <> body["data"]["access_token"])
  end

  describe "GET /schedule" do
    test "reads the Intranet matrix, shared cells and labs included", %{conn: conn} do
      body = conn |> logged_in("E001") |> get("/schedule") |> json_response(200)
      %{"term" => term, "classes" => classes} = body["data"]

      assert term == %{"id" => "2026-2", "label" => "2026-II"}

      university = Enum.filter(classes, &(&1["source"] == "university"))
      # The Monday session appears in two time slots upstream, once here.
      assert length(university) == 4

      [monday, wednesday, thursday_a, thursday_b] = university

      assert monday["course"] == %{"code" => "IS-301", "name" => "Base de Datos", "nrc" => nil}
      assert monday["kind"] == "theory"

      assert {monday["weekday"], monday["day"], monday["start"], monday["end"]} ==
               {1, "Lunes", "08:00", "09:45"}

      assert monday["duration_minutes"] == 105
      assert monday["teacher"] == "Garcia Lopez Ana"

      assert monday["room"] == %{
               "campus" => "Huancayo",
               "building" => "Pabellón H",
               "name" => "H 302",
               "capacity" => 40
             }

      # A practice held in a lab is a lab, in the lab's room.
      assert wednesday["kind"] == "lab"
      assert wednesday["room"]["name"] == "LAB_SISTEMAS 2"

      # Two courses sharing one cell, split field by field (same time: by name).
      assert {thursday_a["course"]["name"], thursday_a["section"], thursday_a["room"]["name"]} ==
               {"Etica", "B1", "K 102"}

      assert {thursday_b["course"]["name"], thursday_b["section"], thursday_b["room"]["name"]} ==
               {"Redes", "A1", "K 101"}

      assert thursday_b["teacher"] == "Perez Rojas Juan"
      assert thursday_a["teacher"] == nil

      languages = Enum.filter(classes, &(&1["source"] == "languages"))
      assert Enum.map(languages, & &1["weekday"]) == [1, 3]
      assert hd(languages)["kind"] == "language"
      assert hd(languages)["start"] == "19:00"

      assert body["meta"]["sources"] == %{
               "intranet" => "ok",
               "sigma" => "not_needed",
               "languages" => "ok"
             }
    end

    test "falls back to SIGMA, reading its teacher and lab type", %{conn: conn} do
      body = conn |> logged_in("E004") |> get("/schedule") |> json_response(200)
      [class] = body["data"]["classes"]

      assert class["course"] == %{
               "code" => "IS-401",
               "name" => "Sistemas Operativos",
               "nrc" => "341200"
             }

      assert class["kind"] == "lab"
      assert class["teacher"] == "Quispe Rojas Luis"
      assert class["modality"] == "in_person"
      assert class["room"]["building"] == "Pabellón J"
      assert body["meta"]["sources"]["sigma"] == "ok"
      assert body["meta"]["sources"]["languages"] == "no_access"
    end

    test "an unknown term is a 404", %{conn: conn} do
      conn = conn |> logged_in("E001") |> get("/schedule", %{"term" => "1999-1"})
      assert json_response(conn, 404)["error"]["code"] == "unknown_term"
    end
  end

  test "GET /languages: courses with grades, 0 as no grade", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/languages") |> json_response(200)
    [course] = body["data"]["courses"]

    assert course["id"] == "555"
    assert course["language"] == "Inglés"
    assert course["course"] == "Inglés B1"
    assert course["modality"] == "virtual"
    assert course["current"] == true
    assert course["shift"] == "Noche"
    assert course["room"] == "Aula 5"

    assert course["schedule"] == [
             %{"weekday" => 1, "start" => "19:00", "end" => "20:30", "duration_minutes" => 90},
             %{"weekday" => 3, "start" => "19:00", "end" => "20:30", "duration_minutes" => 90}
           ]

    assert course["grades"] == %{
             "items" => [15.0, 14.0, nil, nil, nil, nil],
             "average" => 14.5
           }
  end

  describe "helpers" do
    test "room text with building, room and capacity" do
      assert Schedule.room("HU", "PABELLON H - H 302 - AFORO: 40") == %{
               campus: "Huancayo",
               building: "Pabellón H",
               name: "H 302",
               capacity: 40
             }

      assert Schedule.room(nil, nil) == %{campus: nil, building: nil, name: nil, capacity: nil}
    end

    test "language days" do
      assert Days.parse_tokens("LU-MA-MI-JU-VI") == [1, 2, 3, 4, 5]
      assert Days.parse_tokens("SA - DO") == [6, 7]
      assert Days.hhmm("8:05:00") == "08:05"
      assert Days.hhmm("25:00") == nil
    end
  end
end
