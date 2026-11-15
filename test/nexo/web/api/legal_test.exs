defmodule Nexo.Web.Api.LegalTest do
  @moduledoc """
  Legal documents: the published version (`GET /legal`), the public HTML
  pages and the record of who accepted which version.
  """
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Db, RateLimiter}
  alias Nexo.Legal
  alias Nexo.People.{Students, Teachers}
  alias Nexo.Security.Auth

  setup %{conn: conn} do
    RateLimiter.reset()

    # The test database is shared: only this module's own records are wiped.
    Mongo.delete_many(Db.conn(), Legal.collection(), %{})
    Mongo.delete_many(Db.conn(), "audit_log", %{action: "legal_accepted"})

    {:ok, student} =
      Students.upsert_from_sigma(%{code: "U01025B", first_name: "Ana", last_name: "Rojas"})

    student_id = Db.id_to_string(student["_id"])
    token = Auth.sign_access_token(:student, student_id)

    %{
      student: put_req_header(conn, "authorization", "Bearer " <> token),
      student_id: student_id,
      anon: conn
    }
  end

  describe "GET /legal" do
    test "publishes version, date, summary and the three documents", %{anon: anon} do
      data = anon |> get("/legal") |> json_response(200) |> Map.fetch!("data")

      assert data["version"] == Legal.version()
      assert data["version"] == 6
      assert data["updated_at"] == "2026-11-15"
      assert [_ | _] = data["summary"]
      assert Enum.all?(data["summary"], &is_binary/1)

      assert Enum.map(data["documents"], & &1["id"]) == ["terms", "privacy", "cookies"]

      for doc <- data["documents"] do
        assert doc["title"] =~ ~r/\S/
        assert URI.parse(doc["url"]).path in ["/terminos", "/privacidad", "/cookies"]
      end
    end
  end

  describe "HTML pages" do
    test "serve the current texts", %{anon: anon} do
      for {path, title} <- [
            {"/terminos", "Términos y Condiciones"},
            {"/privacidad", "Política de Privacidad"},
            {"/privacy", "Política de Privacidad"},
            {"/cookies", "Política de Cookies"}
          ] do
        conn = get(anon, path)
        assert conn.status == 200, path
        assert [type] = get_resp_header(conn, "content-type")
        assert type =~ "text/html"
        assert conn.resp_body =~ title
        assert conn.resp_body =~ "Versión 6"
        assert conn.resp_body =~ "15/11/2026"
        assert conn.resp_body =~ "alessandrovillogas@outlook.es"
        refute conn.resp_body =~ "**"
      end

      privacy = get(anon, "/privacidad").resp_body
      assert privacy =~ "api.nexo.aurx.pro"
      assert privacy =~ "AES-256-GCM"
      assert privacy =~ "Chile Central"
      assert privacy =~ "MongoDB Atlas"
      assert privacy =~ "29733"
      assert privacy =~ "<strong>"
    end

    test "/terms still answers the students' term list, not a legal page", %{anon: anon} do
      conn = get(anon, "/terms")
      refute conn.resp_body =~ "Términos y Condiciones"
    end
  end

  describe "POST /me/legal/accept" do
    test "records the acceptance with a timestamp and audits it",
         %{student: student, student_id: id} do
      body = student |> post("/me/legal/accept", %{version: 6}) |> json_response(200)

      assert body["data"]["version"] == 6
      assert body["data"]["current"] == true
      assert {:ok, _, _} = DateTime.from_iso8601(body["data"]["accepted_at"])

      assert [record] =
               Db.conn()
               |> Mongo.find(Legal.collection(), %{subject_id: id})
               |> Enum.to_list()

      assert record["subject_type"] == "student"
      assert record["version"] == 6
      assert %DateTime{} = record["accepted_at"]

      assert Mongo.find_one(Db.conn(), "audit_log", %{action: "legal_accepted", actor_id: id})
      assert Legal.accepted_version(%{type: :student, id: id}) == 6
    end

    test "keeps every acceptance as evidence", %{student: student, student_id: id} do
      student |> post("/me/legal/accept", %{version: 4}) |> json_response(200)
      body = student |> post("/me/legal/accept", %{version: 6}) |> json_response(200)
      assert body["data"]["current"]

      assert Mongo.count_documents(Db.conn(), Legal.collection(), %{subject_id: id}) == {:ok, 2}
      assert Legal.accepted_version(%{type: :student, id: id}) == 6
    end

    test "teachers can accept too", %{anon: anon} do
      {:ok, teacher} =
        Teachers.upsert_teacher_from_sigma(%{
          code: "LEGAL01",
          first_name: "Luz",
          last_name: "Paz"
        })

      id = Db.id_to_string(teacher["_id"])
      token = Auth.sign_access_token(:teacher, id)

      anon
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/me/legal/accept", %{version: 6})
      |> json_response(200)

      assert Legal.accepted_version(%{type: :teacher, id: id}) == 6
    end

    test "rejects unknown versions and bad params", %{student: student} do
      assert json_response(post(student, "/me/legal/accept", %{version: 99}), 422)["error"][
               "code"
             ] == "unknown_version"

      assert json_response(post(student, "/me/legal/accept", %{version: "x"}), 422)["error"][
               "code"
             ] == "invalid_params"

      assert json_response(post(student, "/me/legal/accept", %{}), 422)["error"]["code"] ==
               "invalid_params"
    end

    test "needs a session", %{anon: anon} do
      assert json_response(post(anon, "/me/legal/accept", %{version: 6}), 401)
    end
  end
end
