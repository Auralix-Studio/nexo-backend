defmodule Nexo.Web.Api.DispatcherTest do
  @moduledoc """
  The route modules end to end: the security chain every request goes through, in
  order, and the one response envelope.
  """
  use Nexo.Web.ConnCase, async: false

  # Rejections and the crash route log on purpose; keep the output clean.
  @moduletag :capture_log

  alias Nexo.Infra.{Cache, Db, RateLimiter}

  alias Nexo.People.Students

  alias Nexo.Security.Auth
  alias Nexo.Web.AppCheckHelper

  setup do
    RateLimiter.reset()
    Mongo.delete_many(Db.conn(), "feature_flags", %{})
    for name <- ~w(account.me test.echo), do: Cache.delete({:flag, name})
    :ok
  end

  defp admin(conn), do: put_req_header(conn, "x-admin-key", "test-admin-key")

  describe "envelope and routing" do
    test "success is wrapped and hardened", %{conn: conn} do
      conn = get(conn, "/status")

      assert %{"ok" => true, "data" => %{"status" => "ok", "service" => "nexo"}} =
               json_response(conn, 200)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["default-src 'none'" <> _] = get_resp_header(conn, "content-security-policy")
    end

    test "unknown path is a 404 in the same shape", %{conn: conn} do
      body = conn |> get("/nope") |> json_response(404)
      assert %{"ok" => false, "error" => %{"code" => "not_found"}} = body
    end

    test "wrong method is a 405 with Allow", %{conn: conn} do
      conn = delete(conn, "/status")
      assert json_response(conn, 405)["error"]["code"] == "method_not_allowed"
      assert get_resp_header(conn, "allow") == ["GET"]
    end

    test "a literal segment wins over a parameter", %{conn: conn} do
      body = conn |> post("/test/echo/search", %{}) |> json_response(200)
      assert body["data"] == %{"route" => "search"}
    end

    test "a crash answers 500 without leaking the error", %{conn: conn} do
      conn = get(conn, "/test/boom")
      body = json_response(conn, 500)

      assert body["error"]["code"] == "internal_error"
      refute conn.resp_body =~ "secret internal detail"
      assert is_binary(body["request_id"])
    end
  end

  describe "params" do
    test "only declared params reach the route, coerced", %{conn: conn} do
      body =
        conn
        |> post("/test/echo/abc", %{"name" => " Ana ", "count" => "3", "role" => "admin"})
        |> json_response(200)

      assert body["data"] == %{"slot" => "abc", "name" => "Ana", "count" => 3}
    end

    test "invalid params answer 422 with every field", %{conn: conn} do
      body =
        conn
        |> post("/test/echo/ABC", %{"count" => "9", "mode" => "warp"})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      fields = Enum.map(body["error"]["details"], & &1["field"])
      assert Enum.sort(fields) == ~w(count mode name slot)
    end
  end

  describe "authentication" do
    setup do
      Mongo.delete_many(Db.conn(), "students", %{})

      {:ok, student} =
        Students.upsert_from_sigma(%{code: "E900", first_name: "Ana", last_name: "Rojas"})

      %{token: Auth.sign_access_token(:student, Db.id_to_string(student["_id"]))}
    end

    test "no token is a 401", %{conn: conn} do
      assert json_response(get(conn, "/me"), 401)["error"]["code"] == "unauthorized"
    end

    test "a forged token is a 401", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer not-a-token")
      assert json_response(get(conn, "/me"), 401)["error"]["code"] == "unauthorized"
    end

    test "a valid token returns only public profile fields", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/me")
        |> json_response(200)

      assert body["data"]["type"] == "student"

      assert body["data"]["profile"] == %{
               "code" => "E900",
               "first_name" => "Ana",
               "last_name" => "Rojas"
             }
    end

    test "a valid token of the wrong subject type is a 403", %{conn: conn, token: token} do
      conn = put_req_header(conn, "authorization", "Bearer " <> token)

      assert json_response(get(conn, "/test/teachers-only"), 403)["error"]["code"] ==
               "forbidden"
    end

    test "admin routes need the admin key", %{conn: conn} do
      assert json_response(get(conn, "/admin/catalog"), 401)

      body = conn |> admin() |> get("/admin/catalog") |> json_response(200)
      names = Enum.map(body["data"]["routes"], & &1["name"])
      assert "account.me" in names and "system.status" in names
    end
  end

  describe "rate limits" do
    test "a route limit answers 429 with Retry-After", %{conn: conn} do
      assert json_response(get(conn, "/test/limited"), 200)
      assert json_response(get(conn, "/test/limited"), 200)

      conn = get(conn, "/test/limited")
      assert json_response(conn, 429)["error"]["code"] == "rate_limited"
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) in 1..60
    end

    test "the per-IP limit applies before routing", %{conn: conn} do
      previous = Application.get_env(:nexo, :rate_limits)
      Application.put_env(:nexo, :rate_limits, Keyword.put(previous, :ip_per_minute, 1))
      on_exit(fn -> Application.put_env(:nexo, :rate_limits, previous) end)

      assert json_response(get(conn, "/status"), 200)
      assert json_response(get(conn, "/nope"), 429)
    end
  end

  describe "feature flags" do
    test "switching a route off answers 503 until it is back on", %{conn: conn} do
      set = fn enabled ->
        conn |> admin() |> put("/admin/flags/test.echo", %{"enabled" => enabled})
      end

      assert json_response(set.(false), 200)["data"] == %{
               "name" => "test.echo",
               "enabled" => false
             }

      body = conn |> post("/test/echo/abc", %{"name" => "Ana"}) |> json_response(503)
      assert body["error"]["code"] == "feature_disabled"

      assert json_response(set.(true), 200)
      assert json_response(post(conn, "/test/echo/abc", %{"name" => "Ana"}), 200)
    end

    test "unknown flags and admin routes cannot be switched", %{conn: conn} do
      for name <- ~w(nothing.here admin.flags.set) do
        conn = conn |> admin() |> put("/admin/flags/#{name}", %{"enabled" => false})
        assert json_response(conn, 404)["error"]["code"] == "unknown_flag"
      end
    end
  end

  describe "client IP" do
    alias Nexo.Web.ClientIp

    test "trusts cf-connecting-ip only from a trusted proxy", %{conn: conn} do
      forwarded = put_req_header(conn, "cf-connecting-ip", "203.0.113.7")
      assert ClientIp.get(%{forwarded | remote_ip: {127, 0, 0, 1}}) == "203.0.113.7"
      assert ClientIp.get(%{forwarded | remote_ip: {198, 51, 100, 1}}) == "198.51.100.1"
    end

    test "reads x-forwarded-for from the right, past trusted proxies", %{conn: conn} do
      previous = Application.get_env(:nexo, :trusted_proxies)
      Application.put_env(:nexo, :trusted_proxies, ["10.0.0.0/8", "::1"])
      on_exit(fn -> Application.put_env(:nexo, :trusted_proxies, previous) end)

      # The client wrote 1.2.3.4 itself; the ingress appended the real peer.
      conn =
        conn
        |> put_req_header("x-forwarded-for", "1.2.3.4, 203.0.113.9, 10.1.2.3")
        |> Map.put(:remote_ip, {10, 4, 5, 6})

      assert ClientIp.get(conn) == "203.0.113.9"
    end

    test "parses CIDR ranges" do
      assert {_, 8, 32} = ClientIp.parse_range("10.0.0.0/8")
      assert {_, 128, 128} = ClientIp.parse_range("::1")
      assert ClientIp.parse_range("10.0.0.0/40") == nil
      assert ClientIp.parse_range("nope") == nil
    end
  end

  describe "host guard" do
    setup do
      Application.put_env(:nexo, :allowed_hosts, ["api.nexo.aurx.pro"])
      on_exit(fn -> Application.put_env(:nexo, :allowed_hosts, []) end)
    end

    test "only the API domain is answered", %{conn: conn} do
      other = get(%{conn | host: "nexo-api.chilecentral.azurecontainerapps.io"}, "/status")
      assert other.status == 421

      assert json_response(get(%{conn | host: "api.nexo.aurx.pro"}, "/status"), 200)
    end

    test "health probes pass on any host", %{conn: conn} do
      assert get(%{conn | host: "10.0.0.7"}, "/health").status in [200, 503]
    end
  end

  describe "App Check" do
    test "enforce mode refuses requests without a valid app token", %{conn: conn} do
      key = AppCheckHelper.enable(:enforce)
      now = System.system_time(:second)

      assert json_response(get(conn, "/status"), 401)["error"]["code"] ==
               "app_not_verified"

      for bad <- [
            "garbage",
            AppCheckHelper.token(key, %{"exp" => now - 10}),
            AppCheckHelper.token(key, %{"iss" => "https://evil.example/123456789"}),
            AppCheckHelper.token(key, %{"aud" => ["projects/999"]}),
            AppCheckHelper.token(key, %{"sub" => "1:123456789:android:clone"}),
            AppCheckHelper.token(key, %{}, %{"alg" => "none"}),
            AppCheckHelper.token(:public_key.generate_key({:rsa, 2048, 65_537}))
          ] do
        conn = put_req_header(conn, "x-firebase-appcheck", bad)

        assert json_response(get(conn, "/status"), 401)["error"]["code"] ==
                 "app_not_verified"
      end

      good = put_req_header(conn, "x-firebase-appcheck", AppCheckHelper.token(key))
      assert json_response(get(good, "/status"), 200)
    end

    test "it also guards the legacy /api/v1 routes, but not health checks", %{conn: conn} do
      AppCheckHelper.enable(:enforce)

      assert json_response(post(conn, "/api/v1/guardian/login", %{}), 401) == %{
               "error" => "app_not_verified"
             }

      assert get(conn, "/health").status in [200, 503]
    end

    test "monitor mode only logs", %{conn: conn} do
      AppCheckHelper.enable(:monitor)
      assert json_response(get(conn, "/status"), 200)
    end

    test "enforce without a project number fails closed", %{conn: conn} do
      key = AppCheckHelper.enable(:enforce)
      config = Application.get_env(:nexo, :app_check)
      Application.put_env(:nexo, :app_check, Keyword.put(config, :project_number, nil))

      conn = put_req_header(conn, "x-firebase-appcheck", AppCheckHelper.token(key))
      assert json_response(get(conn, "/status"), 401)
    end
  end
end
