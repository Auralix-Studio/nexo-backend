defmodule Nexo.Web.Api.IntegrationsTest do
  @moduledoc """
  Sharing the schedule and profile with other apps: the calendar link and
  Connect with Nexo (device flow), end to end.
  """
  use Nexo.Web.ConnCase, async: false

  # Rejections log on purpose; keep the output clean.
  @moduletag :capture_log

  alias Nexo.Infra.{Db, RateLimiter}
  alias Nexo.Integrations.Calendar
  alias Nexo.People.Students
  alias Nexo.Security.Auth
  alias Nexo.Web.AppCheckHelper

  @shared %{
    "profile" => %{
      "code" => "U01025B",
      "first_name" => "Ana",
      "last_name" => "Rojas",
      "career" => "Ingeniería de Sistemas"
    },
    "schedule" => %{
      "term" => %{"name" => "2026-2", "start" => "2026-08-24", "end" => "2026-12-12"},
      "classes" => [
        %{
          "course" => "Base de Datos, Teoría; I",
          "weekday" => 1,
          "start" => "08:00",
          "end" => "09:45",
          "room" => "Pabellón H · H 302",
          "section" => "A1"
        },
        %{"course" => "Redes", "weekday" => 4, "start" => "14:00", "end" => "16:30"}
      ]
    }
  }

  setup %{conn: conn} do
    RateLimiter.reset()

    wipe(~w(students integration_data calendar_feeds integration_clients
                integration_requests integration_grants))

    {:ok, student} =
      Students.upsert_from_sigma(%{code: "U01025B", first_name: "Ana", last_name: "Rojas"})

    token = Auth.sign_access_token(:student, Db.id_to_string(student["_id"]))
    %{student: put_req_header(conn, "authorization", "Bearer " <> token), anon: conn}
  end

  defp share(conn), do: put(conn, "/me/shared", @shared)

  describe "shared data" do
    test "is validated, stored and read back", %{student: student} do
      assert json_response(share(student), 200)["data"]["profile"]["code"] == "U01025B"

      body = student |> get("/me/shared") |> json_response(200)
      assert length(body["data"]["shared"]["schedule"]["classes"]) == 2
      assert body["data"]["calendar_enabled"] == false

      bad = put(student, "/me/shared", %{"schedule" => %{"classes" => [%{"course" => "X"}]}})
      assert json_response(bad, 422)["error"]["code"] == "invalid_params"
    end

    test "only students may share", %{anon: anon} do
      assert json_response(put(anon, "/me/shared", @shared), 401)
    end
  end

  describe "calendar link" do
    test "needs shared data, serves iCalendar and rotates", %{student: student, anon: anon} do
      assert json_response(post(student, "/me/calendar"), 409)["error"]["code"] ==
               "nothing_shared"

      share(student)
      body = student |> post("/me/calendar") |> json_response(200)
      assert body["data"]["webcal_url"] =~ ~r{^webcal://}
      assert body["data"]["google_url"] =~ "calendar.google.com"
      path = URI.parse(body["data"]["url"]).path

      feed = get(anon, path)
      assert feed.status == 200
      assert [content_type] = get_resp_header(feed, "content-type")
      assert content_type =~ "text/calendar"
      ics = feed.resp_body
      assert ics =~ "BEGIN:VCALENDAR\r\n"
      assert ics =~ "TZID:America/Lima"
      assert ics =~ "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261213T045959Z"
      assert ics =~ "DTSTART;TZID=America/Lima:20260824T080000"
      assert ics =~ "DTSTART;TZID=America/Lima:20260827T140000"
      assert ics =~ "SUMMARY:Base de Datos\\, Teoría\\; I"

      # Turning it on again rotates the key: the old link stops working.
      _ = student |> post("/me/calendar") |> json_response(200)
      assert get(anon, path).status == 404

      student |> delete("/me/calendar") |> json_response(200)
      assert get(anon, "/calendar/" <> String.duplicate("a", 43) <> ".ics").status == 404
    end

    test "long lines are folded at 75 octets" do
      shared = %{
        "schedule" => %{
          "classes" => [
            %{
              "course" => String.duplicate("Ñandú ", 30),
              "weekday" => 2,
              "start" => "10:00",
              "end" => "11:00"
            }
          ]
        }
      }

      ics = Calendar.to_ics(shared, "seed", ~D[2026-08-24])

      for line <- String.split(ics, "\r\n", trim: true),
          do: assert(byte_size(line) <= 75)

      assert ics =~ "\r\n "
    end
  end

  describe "Connect with Nexo" do
    defp register(anon) do
      anon
      |> put_req_header("x-admin-key", "test-admin-key")
      |> post("/admin/integrations/clients", %{"name" => "RutinaApp"})
      |> json_response(201)
      |> get_in(["data", "client_id"])
    end

    defp poll(anon, client_id, device_code) do
      post(anon, "/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => client_id,
        "device_code" => device_code
      })
    end

    # The app must wait between polls; tests move the last poll back instead.
    defp let_time_pass do
      past = DateTime.add(Db.now(), -60, :second)

      Mongo.update_many(Db.conn(), "integration_requests", %{}, %{"$set" => %{last_poll_at: past}})
    end

    test "device flow: request, approval in Nexo, scoped access, refresh, revoke",
         %{student: student, anon: anon} do
      share(student)
      client_id = register(anon)

      start =
        anon
        |> post("/oauth/device", %{"client_id" => client_id, "scope" => "schedule"})
        |> json_response(200)

      assert start["interval"] == 5
      assert start["verification_uri_complete"] =~ start["user_code"]

      assert json_response(poll(anon, client_id, start["device_code"]), 400) == %{
               "error" => "authorization_pending"
             }

      assert json_response(poll(anon, client_id, start["device_code"]), 400)["error"] ==
               "slow_down"

      preview =
        student |> get("/me/connections/requests/#{start["user_code"]}") |> json_response(200)

      assert preview["data"]["client"]["name"] == "RutinaApp"
      assert preview["data"]["scopes"] == ["schedule"]

      student
      |> post("/me/connections/requests/#{start["user_code"]}", %{"decision" => "approve"})
      |> json_response(200)

      let_time_pass()
      tokens = anon |> poll(client_id, start["device_code"]) |> json_response(200)
      assert tokens["scope"] == "schedule" and tokens["token_type"] == "Bearer"

      # The device code is single use.
      assert json_response(poll(anon, client_id, start["device_code"]), 400)["error"] ==
               "invalid_grant"

      app = put_req_header(anon, "authorization", "Bearer " <> tokens["access_token"])
      schedule = app |> get("/integrations/schedule") |> json_response(200)
      assert length(schedule["data"]["schedule"]["classes"]) == 2

      # Only the granted scope.
      assert json_response(get(app, "/integrations/profile"), 403)

      refreshed =
        anon
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "client_id" => client_id,
          "refresh_token" => tokens["refresh_token"]
        })
        |> json_response(200)

      assert json_response(get(app, "/integrations/schedule"), 401)
      app = put_req_header(anon, "authorization", "Bearer " <> refreshed["access_token"])
      assert json_response(get(app, "/integrations/schedule"), 200)

      [connection] =
        student |> get("/me/shared") |> json_response(200) |> get_in(["data", "connections"])

      assert connection["name"] == "RutinaApp"

      student |> delete("/me/connections/#{connection["id"]}") |> json_response(200)
      assert json_response(get(app, "/integrations/schedule"), 401)
    end

    test "a denied request and an unknown app", %{student: student, anon: anon} do
      share(student)
      client_id = register(anon)

      start =
        anon
        |> post("/oauth/device", %{"client_id" => client_id, "scope" => "profile"})
        |> json_response(200)

      student
      |> post("/me/connections/requests/#{start["user_code"]}", %{"decision" => "deny"})
      |> json_response(200)

      let_time_pass()

      assert json_response(poll(anon, client_id, start["device_code"]), 400)["error"] ==
               "access_denied"

      assert json_response(
               post(anon, "/oauth/device", %{"client_id" => "nxc_nope", "scope" => "profile"}),
               401
             ) == %{"error" => "invalid_client"}

      assert json_response(
               post(anon, "/oauth/device", %{"client_id" => client_id, "scope" => "grades"}),
               400
             ) == %{"error" => "invalid_scope"}
    end

    test "suspending the app cuts its tokens", %{student: student, anon: anon} do
      share(student)
      client_id = register(anon)

      start =
        anon
        |> post("/oauth/device", %{"client_id" => client_id, "scope" => "profile"})
        |> json_response(200)

      post(student, "/me/connections/requests/#{start["user_code"]}", %{"decision" => "approve"})
      let_time_pass()
      tokens = anon |> poll(client_id, start["device_code"]) |> json_response(200)
      app = put_req_header(anon, "authorization", "Bearer " <> tokens["access_token"])

      assert json_response(get(app, "/integrations/profile"), 200)["data"]["profile"]["code"] ==
               "U01025B"

      anon
      |> put_req_header("x-admin-key", "test-admin-key")
      |> put("/admin/integrations/clients/#{client_id}", %{"status" => "suspended"})
      |> json_response(200)

      assert json_response(get(app, "/integrations/profile"), 401)
    end

    test "third-party routes skip app attestation; student routes keep it",
         %{student: student, anon: anon} do
      AppCheckHelper.enable(:enforce)

      assert json_response(put(student, "/me/shared", @shared), 401)["error"]["code"] ==
               "app_not_verified"

      assert json_response(get(anon, "/integrations/schedule"), 401)["error"]["code"] ==
               "unauthorized"
    end
  end

  test "integration routes cannot demand attestation, and only they take scopes" do
    alias Nexo.Web.Api.Route

    assert_raise ArgumentError, ~r/cannot require app attestation/, fn ->
      Route.build_spec!(Demo,
        name: "x",
        method: :get,
        path: "/x",
        auth: :integration,
        scopes: ["profile"],
        attest: true
      )
    end

    assert_raise ArgumentError, ~r/only integration routes take scopes/, fn ->
      Route.build_spec!(Demo, name: "x", method: :get, path: "/x", scopes: ["profile"])
    end

    assert_raise ArgumentError, ~r/need scopes/, fn ->
      Route.build_spec!(Demo, name: "x", method: :get, path: "/x", auth: :integration)
    end
  end
end
