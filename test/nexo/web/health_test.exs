defmodule Nexo.Web.HealthTest do
  use Nexo.Web.ConnCase, async: true

  test "GET /health responde ok con MongoDB accesible", %{conn: conn} do
    assert %{"status" => "ok", "db" => "ok"} =
             conn |> get("/health") |> json_response(200)
  end
end
