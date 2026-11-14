defmodule Nexo.Web.Api.PasswordTest do
  @moduledoc "POST /auth/password changes the university password through SIGMA."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Db, RateLimiter}

  setup do
    RateLimiter.reset()

    for c <- ~w(students refresh_tokens upstream_sessions) do
      Mongo.delete_many(Db.conn(), c, %{})
    end

    token =
      build_conn()
      |> post("/auth/login", %{"user" => "E001", "password" => "ok"})
      |> json_response(200)
      |> get_in(["data", "access_token"])

    {:ok, token: token}
  end

  defp change(conn, token, current, new) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/auth/password", %{"current_password" => current, "new_password" => new})
  end

  test "SIGMA accepts the change", %{conn: conn, token: token} do
    assert change(conn, token, "ok", "nueva-clave") |> json_response(200) ==
             %{"ok" => true, "data" => %{"changed" => true}}
  end

  test "a wrong current password is a 422 with SIGMA's message", %{conn: conn, token: token} do
    body = change(conn, token, "mal", "nueva-clave") |> json_response(422)
    assert body["error"]["code"] == "password_rejected"
    assert body["error"]["message"] == "La contraseña actual no es correcta."
  end

  test "a too short new password is refused before SIGMA", %{conn: conn, token: token} do
    assert change(conn, token, "ok", "123") |> json_response(422)
  end
end
