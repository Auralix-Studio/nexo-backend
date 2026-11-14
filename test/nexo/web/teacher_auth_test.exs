defmodule Nexo.Web.TeacherAuthTest do
  @moduledoc "Teacher records created at login and their allowlist status."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Db, RateLimiter}
  alias Nexo.People.Teachers

  setup do
    RateLimiter.reset()
    wipe(~w(teachers refresh_tokens upstream_sessions))
  end

  defp status(conn, user) do
    conn
    |> logged_in(user)
    |> get("/me")
    |> json_response(200)
    |> get_in(["data", "profile", "status"])
  end

  test "a first login registers the teacher as pending", %{conn: conn} do
    assert status(conn, "D001") == "pendiente"
  end

  test "a preauthorized code is authorized without approval", %{conn: conn} do
    assert status(conn, "PRE-001") == "autorizado"
    assert Teachers.get_teacher_by_code("PRE-001")["authorized_by"] == "preautorizado"
  end

  test "preauthorization does not bring back a suspended teacher", %{conn: conn} do
    status(conn, "PRE-001")

    Mongo.update_one(Db.conn(), "teachers", %{sigma_code: "PRE-001"}, %{
      "$set" => %{"status" => "suspendido"}
    })

    assert status(conn, "PRE-001") == "suspendido"
  end
end
