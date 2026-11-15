defmodule Nexo.Web.Api.NotificationsTest do
  @moduledoc "Push devices and notification preferences."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Cache, Db, RateLimiter}
  alias Nexo.Notifications.{Devices, Settings}
  alias Nexo.People.Teachers

  @token "fcm:APA91bH-example_token_1234567890"

  setup do
    RateLimiter.reset()

    wipe(~w(students refresh_tokens upstream_sessions devices notification_settings))

    :ok
  end

  defp subject_of(code) do
    %{"_id" => id} = Mongo.find_one(Db.conn(), "students", %{code: code})
    %{type: :student, id: Db.id_to_string(id)}
  end

  test "a registered device turns grade notifications on by default", %{conn: conn} do
    authed = logged_in(conn, "E001")

    body =
      authed
      |> post("/me/devices", %{"token" => @token, "platform" => "android"})
      |> json_response(201)

    assert body["data"] == %{"registered" => true, "notifications" => %{"grades" => true}}
    assert Devices.tokens(subject_of("E001")) == [@token]

    assert authed |> get("/me/notifications") |> json_response(200) |> Map.get("data") ==
             %{"grades" => true, "devices" => 1}
  end

  test "registering again refreshes the device instead of duplicating it", %{conn: conn} do
    authed = logged_in(conn, "E001")

    for _ <- 1..2,
        do: authed |> post("/me/devices", %{"token" => @token, "platform" => "android"})

    assert Mongo.count_documents!(Db.conn(), "devices", %{}) == 1
  end

  test "a token moves to the account that logs in on the phone", %{conn: conn} do
    logged_in(conn, "E001") |> post("/me/devices", %{"token" => @token, "platform" => "android"})
    logged_in(conn, "E004") |> post("/me/devices", %{"token" => @token, "platform" => "android"})

    assert Devices.tokens(subject_of("E001")) == []
    assert Devices.tokens(subject_of("E004")) == [@token]
  end

  test "invalid tokens and platforms are rejected", %{conn: conn} do
    authed = logged_in(conn, "E001")

    conn = post(authed, "/me/devices", %{"token" => "short", "platform" => "symbian"})
    fields = json_response(conn, 422)["error"]["details"] |> Enum.map(& &1["field"])
    assert Enum.sort(fields) == ["platform", "token"]
  end

  test "DELETE /me/devices/:token forgets only the user's own token", %{conn: conn} do
    authed = logged_in(conn, "E001")
    authed |> post("/me/devices", %{"token" => @token, "platform" => "android"})

    logged_in(conn, "E004") |> delete("/me/devices/" <> @token) |> json_response(200)
    assert Devices.tokens(subject_of("E001")) == [@token]

    assert authed |> delete("/me/devices/" <> @token) |> json_response(200) |> Map.get("data") ==
             %{"registered" => false}

    assert Devices.tokens(subject_of("E001")) == []
  end

  test "PUT /me/notifications turns grades off and on", %{conn: conn} do
    authed = logged_in(conn, "E001")

    body = authed |> put("/me/notifications", %{"grades" => false}) |> json_response(200)
    assert body["data"] == %{"grades" => false, "devices" => 0}

    assert authed |> get("/me/notifications") |> json_response(200) |> get_in(["data", "grades"]) ==
             false

    body = authed |> put("/me/notifications", %{"grades" => true}) |> json_response(200)
    assert body["data"]["grades"] == true
  end

  test "PUT /me/notifications needs a boolean", %{conn: conn} do
    conn = conn |> logged_in("E001") |> put("/me/notifications", %{"grades" => "maybe"})
    assert json_response(conn, 422)
  end

  test "notification routes are for students only", %{conn: conn} do
    conn = conn |> logged_in("D001") |> get("/me/notifications")
    assert json_response(conn, 403)
  end

  test "logout forgets the user's devices", %{conn: conn} do
    authed = logged_in(conn, "E001")
    subject = subject_of("E001")
    authed |> post("/me/devices", %{"token" => @token, "platform" => "android"})

    authed |> post("/auth/logout") |> json_response(200)

    assert Devices.tokens(subject) == []
  end

  describe "a teacher saving grades" do
    setup do
      case Teachers.get_teacher_by_code("D001") do
        %{"_id" => id} -> Cache.invalidate_subject(%{type: :teacher, id: Db.id_to_string(id)})
        _ -> :ok
      end

      # U002 is in the mock section and has the app with notifications on.
      {:ok, %{inserted_id: id}} = Mongo.insert_one(Db.conn(), "students", %{code: "U002"})
      subject = %{type: :student, id: Db.id_to_string(id)}
      :ok = Devices.register(subject, @token, "android")
      :ok = Settings.ensure(subject)
      {:ok, subject: subject}
    end

    defp save_grade(conn) do
      teacher = logged_in(conn, "D001")
      id = teacher |> get("/teaching/sections") |> get_in_json(["data", Access.at(0), "id"])

      teacher
      |> put("/teaching/sections/#{id}/grades", %{
        "unit_id" => 101,
        "type_id" => 11,
        "grades" => [%{"student" => "U002", "value" => 12}]
      })
      |> json_response(200)
    end

    defp get_in_json(conn, path), do: conn |> json_response(200) |> get_in(path)

    test "notifies the student at once with course, unit, type and grade", %{conn: conn} do
      assert %{"saved" => 1} = save_grade(conn)["data"]

      assert_receive {:fcm, %{token: @token} = message}, 2_000
      assert message.notification.title == "Nueva nota · Base de Datos I"
      assert message.notification.body =~ "Evidencia de Conocimiento: 12"
      assert message.data == %{type: "grade", term: "2026-2", course: "341119"}
    end

    test "does nothing when the student turned grade notifications off",
         %{conn: conn, subject: subject} do
      :ok = Settings.put_grades(subject, false)
      save_grade(conn)
      refute_receive {:fcm, _}, 500
    end
  end
end
