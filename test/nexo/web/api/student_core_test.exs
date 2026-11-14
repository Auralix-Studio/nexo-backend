defmodule Nexo.Web.Api.StudentCoreTest do
  @moduledoc """
  Module 1 of the Nexo API: one login that opens the university sessions on
  the server, and the student's terms and profile in clean JSON.
  """
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Academic.Terms
  alias Nexo.Infra.{Db, RateLimiter}
  alias Nexo.Upstream.{Normalize, Sessions}

  setup do
    RateLimiter.reset()

    for c <- ~w(students teachers refresh_tokens upstream_sessions) do
      Mongo.delete_many(Db.conn(), c, %{})
    end

    :ok
  end

  defp login(conn, user, password \\ "ok"),
    do: post(conn, "/auth/login", %{"user" => user, "password" => password})

  defp logged_in(conn, user \\ "E001") do
    body = conn |> login(user) |> json_response(200)
    {put_req_header(conn, "authorization", "Bearer " <> body["data"]["access_token"]), body}
  end

  defp subject_of(code) do
    %{"_id" => id} = Mongo.find_one(Db.conn(), "students", %{code: code})
    %{type: :student, id: Db.id_to_string(id)}
  end

  describe "POST /auth/login" do
    test "a student gets Nexo tokens and every university session, never the password",
         %{conn: conn} do
      body = conn |> login("E001") |> json_response(200)
      data = body["data"]

      assert data["user"]["role"] == "student"

      assert data["user"]["name"] == %{
               "first" => "José",
               "last" => "Rojas",
               "full" => "José Rojas"
             }

      assert data["sources"] == %{"sigma" => "ok", "intranet" => "ok", "languages" => "ok"}
      assert is_binary(data["access_token"]) and is_binary(data["refresh_token"])

      assert Sessions.get(subject_of("E001")) == %{
               sigma: "tok-E001",
               intranet: "PHPSESSID=E001",
               languages: "lang-E001"
             }

      raw = Mongo.find_one(Db.conn(), "upstream_sessions", %{})
      refute inspect(raw) =~ "tok-E001"
    end

    test "wrong credentials are a 401, not an outage", %{conn: conn} do
      assert json_response(login(conn, "E001", "bad"), 401)["error"]["code"] ==
               "invalid_credentials"
    end

    test "with SIGMA down, the Intranet confirms the password", %{conn: conn} do
      data = conn |> login("down") |> json_response(200) |> Map.fetch!("data")

      assert data["user"]["role"] == "student"
      assert data["sources"]["sigma"] == "unavailable"
      assert data["sources"]["intranet"] == "ok"
    end

    test "a teacher logs in with only the SIGMA session", %{conn: conn} do
      data = conn |> login("D001") |> json_response(200) |> Map.fetch!("data")

      assert data["user"]["role"] == "teacher"
      assert data["sources"]["intranet"] == "not_applicable"
    end
  end

  describe "GET /terms" do
    test "newest first, active from SIGMA, one id and label format", %{conn: conn} do
      {conn, _} = logged_in(conn)
      body = conn |> get("/terms") |> json_response(200)

      assert body["data"] == [
               %{
                 "id" => "2026-2",
                 "year" => 2026,
                 "number" => 2,
                 "label" => "2026-II",
                 "active" => true
               },
               %{
                 "id" => "2026-1",
                 "year" => 2026,
                 "number" => 1,
                 "label" => "2026-I",
                 "active" => false
               },
               %{
                 "id" => "2025-2",
                 "year" => 2025,
                 "number" => 2,
                 "label" => "2025-II",
                 "active" => false
               }
             ]

      assert body["meta"]["sources"] == %{"sigma" => "ok", "intranet" => "ok"}
    end

    test "without SIGMA the newest term is the active one" do
      [newest | _] =
        Terms.merge([], [
          %{year: 2025, number: 2, active: false},
          %{year: 2026, number: 1, active: false}
        ])

      assert newest.id == "2026-1" and newest.active
    end

    test "an expired university session asks the app to log in again", %{conn: conn} do
      {conn, _} = logged_in(conn)
      subject = subject_of("E001")
      Sessions.put(subject, %{sigma: "tok-vencido", intranet: "PHPSESSID=expired"})

      assert json_response(get(conn, "/terms"), 401)["error"]["code"] == "reauth_required"
      assert Sessions.get(subject) == %{}
    end
  end

  describe "GET /profile" do
    test "merges SIGMA and the Intranet, with the right credits", %{conn: conn} do
      {conn, _} = logged_in(conn)
      body = conn |> get("/profile") |> json_response(200)
      profile = body["data"]

      assert profile["code"] == "E001"
      assert profile["career"] == "Ingeniería de Sistemas y Computación"
      assert profile["faculty"] == "Ingeniería"
      assert profile["campus"] == "Huancayo"
      assert profile["modality"] == "in_person"
      assert profile["current_cycle"] == 7
      assert profile["study_plan"] == "2015"
      assert profile["specialty"] == nil
      assert profile["enrolled"] == true
      assert profile["last_enrollment"] == "2026-2"
      # Approved credits from SIGMA; the Intranet's 22 is this term's enrollment.
      assert profile["credits"] == %{
               "approved" => 168,
               "required" => 220,
               "enrolled_this_term" => 22
             }

      assert profile["average"] == %{"cumulative" => 14.12}
      assert profile["photo_url"] == Normalize.photo_url("E001")
      assert body["meta"]["sources"] == %{"sigma" => "ok", "intranet" => "ok"}
    end

    test "is for students only", %{conn: conn} do
      {conn, _} = logged_in(conn, "D001")
      assert json_response(get(conn, "/profile"), 403)
    end
  end

  test "logout ends the Nexo session and forgets the university ones", %{conn: conn} do
    {authed, body} = logged_in(conn)
    authed |> post("/auth/logout") |> json_response(200)

    assert Sessions.get(subject_of("E001")) == %{}

    refresh = post(conn, "/auth/refresh", %{"refresh_token" => body["data"]["refresh_token"]})
    assert json_response(refresh, 401)
  end

  describe "Normalize" do
    test "placeholders become nil and strings become real types" do
      for blank <- [nil, "", " ", "-", "--", "-------", "No hay datos"],
          do: assert(Normalize.text(blank) == nil)

      assert Normalize.number("3.000") == 3.0
      assert Normalize.number("11,60") == 11.6
      assert Normalize.number("15   ") == 15.0
      assert Normalize.int("07") == 7
      assert Normalize.positive("0") == nil
      assert Normalize.bool("True") and Normalize.bool("1") and not Normalize.bool("0")
    end

    test "dates in every upstream format become ISO" do
      assert Normalize.date("28/04/2026") == "2026-04-28"
      assert Normalize.date("12-06-2026") == "2026-06-12"
      assert Normalize.date("2026-10-07T12:59:09.93-05:00") == "2026-10-07"
      assert Normalize.date("31/02/2026") == nil
    end

    test "names, campuses and modalities" do
      assert Normalize.title("INGENIERÍA DE SISTEMAS Y COMPUTACIÓN") ==
               "Ingeniería de Sistemas y Computación"

      assert Normalize.title("CONTABILIDAD II") == "Contabilidad II"
      assert Normalize.campus("HU") == "Huancayo"
      assert Normalize.modality("A DISTANCIA") == "distance"
      assert Normalize.term(2011, 0) == {"2011-0", "2011-0"}
    end
  end
end
