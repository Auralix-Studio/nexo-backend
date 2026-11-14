defmodule Nexo.Web.Api.CampusTest do
  @moduledoc "Module 6 of the Nexo API: enrollment certificate, publications and Wi-Fi."
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Campus.Wifi
  alias Nexo.Infra.{Db, RateLimiter}

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

  test "GET /enrollment: typed certificate data, placeholders as null", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/enrollment") |> json_response(200)
    data = body["data"]

    assert data["term"] == %{"id" => "2026-2", "label" => "2026-II"}

    assert data["student"] == %{
             "code" => "E001",
             "name" => "Rojas Quispe Jose",
             "photo_url" => "https://academico.upla.edu.pe/x.jpg"
           }

    assert data["faculty"] == "Ingeniería"

    assert data["career"] == %{
             "label" => "Carrera",
             "name" => "Ingeniería de Sistemas y Computación"
           }

    # "-------" upstream.
    assert data["specialty"] == nil
    assert {data["study_plan"], data["cycle"], data["modality"]} == {"2015", 7, "in_person"}

    assert data["courses"] == [
             %{
               "code" => "IS-301",
               "name" => "Base de Datos",
               "cycle" => 7,
               "section" => "A1",
               "credits" => 3
             },
             %{
               "code" => "IS-302",
               "name" => "Redes",
               "cycle" => 7,
               "section" => "A1",
               "credits" => 4
             }
           ]

    assert data["total_credits"] == 22
    assert {:ok, _} = Date.from_iso8601(data["issued_at"])
  end

  test "GET /enrollment for a term without rows is empty, not broken", %{conn: conn} do
    body =
      conn |> logged_in("E001") |> get("/enrollment", %{"term" => "2025-2"}) |> json_response(200)

    assert body["data"]["courses"] == []
    assert body["data"]["student"]["code"] == "E001"
    assert body["data"]["total_credits"] == 0
  end

  test "GET /publications", %{conn: conn} do
    body = conn |> logged_in("E001") |> get("/publications") |> json_response(200)

    assert body["data"] == [
             %{
               "id" => 1009,
               "kind" => "image",
               "url" => "https://sigma.upla.edu.pe/Recursos/Imagenes/Anuncios/a.jpeg",
               "adaptive_url" => nil,
               "link_url" => nil,
               "button_text" => nil,
               "downloadable" => false,
               "width" => 1080,
               "height" => 1350
             }
           ]
  end

  test "GET /wifi is never cacheable", %{conn: conn} do
    conn = conn |> logged_in("E001") |> get("/wifi")

    assert json_response(conn, 200)["data"] == %{"user" => "u-e001", "password" => "wifi-secret"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "Wi-Fi key variants" do
    assert Wifi.build([%{"user" => "a", "clave" => "b"}]) == %{user: "a", password: "b"}
    assert Wifi.build(nil) == %{user: nil, password: nil}
  end
end
