defmodule Nexo.Web.Api.TeachingAccountTest do
  @moduledoc "Module 7 of the Nexo API: the teacher's profile, SIGMA's clock and the auxiliary register."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Cache, RateLimiter}
  alias Nexo.People.Teachers

  setup do
    RateLimiter.reset()

    case Teachers.get_teacher_by_code("D001") do
      %{"_id" => id} ->
        Cache.invalidate_subject(%{type: :teacher, id: Nexo.Infra.Db.id_to_string(id)})

      _ ->
        :ok
    end

    :ok
  end

  defp section_id(conn) do
    conn
    |> get("/teaching/sections")
    |> json_response(200)
    |> get_in(["data", Access.at(0), "id"])
  end

  test "GET /teaching/me: clean names, post and photo", %{conn: conn} do
    body = conn |> logged_in() |> get("/teaching/me") |> json_response(200)

    assert body["data"] == %{
             "code" => "D001",
             "first_name" => "Juan Carlos",
             "last_name" => "Perez Rojas",
             "full_name" => "Juan Carlos Perez Rojas",
             "faculty" => "Ingenieria",
             "specialty" => "Docente Ordinario",
             "photo_url" => Nexo.Upstream.Normalize.photo_url("D001")
           }

    assert body["meta"]["source"] == "sigma"
  end

  test "GET /teaching/server-time: SIGMA's Lima wall time", %{conn: conn} do
    body = conn |> logged_in() |> get("/teaching/server-time") |> json_response(200)
    assert body["data"] == %{"now" => "2026-11-05T09:05:07-05:00"}
    assert body["meta"]["source"] == "sigma"
  end

  test "students cannot use the teacher routes", %{conn: conn} do
    conn = conn |> logged_in("E001") |> get("/teaching/me")
    assert conn.status in [401, 403]
  end

  describe "GET /teaching/sections/:id/report" do
    test "PDF by default, as a file with the upstream ids resolved server-side", %{conn: conn} do
      conn = logged_in(conn)
      id = section_id(conn)
      res = get(conn, "/teaching/sections/#{id}/report")

      assert res.status == 200
      assert res.resp_body == "%PDF-fake pdf"
      assert get_resp_header(res, "content-type") == ["application/pdf"]
      assert get_resp_header(res, "cache-control") == ["no-store"]

      assert get_resp_header(res, "content-disposition") ==
               [~s(attachment; filename="Registro auxiliar Base de Datos I A2.pdf")]

      assert_received {:sigma_download, query}

      assert query == %{
               "codSaltem" => "9001",
               "plan" => "2015",
               "asignID" => "341119",
               "tipo" => "pdf",
               # tipoCalif 0 upstream means 12.
               "tipoCalif" => "12"
             }
    end

    test "XLSX on request", %{conn: conn} do
      conn = logged_in(conn)
      res = get(conn, "/teaching/sections/#{section_id(conn)}/report", %{"format" => "xlsx"})

      assert [type] = get_resp_header(res, "content-type")
      assert type =~ "spreadsheetml"
      assert [disposition] = get_resp_header(res, "content-disposition")
      assert disposition =~ ".xlsx\""
    end

    test "another teacher's or an unknown section is a 404", %{conn: conn} do
      conn = conn |> logged_in() |> get("/teaching/sections/sec_0000000000000000/report")
      assert json_response(conn, 404)["error"]["code"] == "unknown_section"
    end

    test "an unsupported format is rejected", %{conn: conn} do
      conn = logged_in(conn)
      res = get(conn, "/teaching/sections/#{section_id(conn)}/report", %{"format" => "exe"})
      assert res.status == 422 or res.status == 400
    end
  end
end
