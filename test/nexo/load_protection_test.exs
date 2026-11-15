defmodule Nexo.LoadProtectionTest do
  @moduledoc """
  What keeps the API and the university standing at 7:55: the login limit
  per user (not per campus IP), the per-user cache with single-flight, the
  Mongo failure path of the university sessions and the outbound circuit
  breaker.
  """
  use Nexo.Web.ConnCase, async: false

  @moduletag :capture_log

  alias Nexo.Infra.{Cache, Db, RateLimiter}
  alias Nexo.Upstream.{Guard, Sessions}

  setup do
    RateLimiter.reset()
    Guard.reset()
    :ok
  end

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp login(conn, user, password),
    do: post(conn, "/auth/login", %{"user" => user, "password" => password})

  defp with_cache(_context) do
    Application.put_env(:nexo, :upstream_cache, true)
    on_exit(fn -> Application.put_env(:nexo, :upstream_cache, false) end)
    :ok
  end

  describe "login rate limit" do
    test "is per user: one user is stopped, others behind the same IP are not",
         %{conn: conn} do
      campus = from_ip(conn, {200, 1, 1, 1})

      for _ <- 1..10, do: assert(json_response(login(campus, "E001", "bad"), 401))

      blocked = login(campus, "E001", "bad")
      assert json_response(blocked, 429)["error"]["code"] == "rate_limited"
      assert [_] = get_resp_header(blocked, "retry-after")

      # Another student on the same NAT IP still logs in.
      assert json_response(login(campus, "E002", "bad"), 401)["error"]["code"] ==
               "invalid_credentials"

      # The same user from another IP is still limited: the key is the user.
      elsewhere = from_ip(conn, {200, 2, 2, 2})
      assert json_response(login(elsewhere, " e001 ", "bad"), 429)
    end

    test "public routes have their own per-IP limit, not the per-user one", %{conn: conn} do
      previous = Application.get_env(:nexo, :rate_limits)

      Application.put_env(
        :nexo,
        :rate_limits,
        previous |> Keyword.put(:public_ip_per_minute, 2) |> Keyword.put(:subject_per_minute, 1)
      )

      on_exit(fn -> Application.put_env(:nexo, :rate_limits, previous) end)
      campus = from_ip(conn, {200, 3, 3, 3})

      assert json_response(get(campus, "/status"), 200)
      assert json_response(get(campus, "/status"), 200)
      assert json_response(get(campus, "/status"), 429)
    end
  end

  describe "per-user cache" do
    setup :with_cache

    test "single-flight: concurrent misses of a key compute once" do
      subject = %{type: :student, id: "sf-#{System.unique_integer([:positive])}"}
      calls = :counters.new(1, [])
      parent = self()

      compute = fn ->
        :counters.add(calls, 1, 1)
        send(parent, {:computing, self()})

        receive do
          :go -> {:ok, %{value: 42}, %{source: "test"}}
        end
      end

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> Cache.subject(subject, :slow, compute, ttl: 60_000) end)
        end

      assert_receive {:computing, owner}, 1_000
      # Let the other callers queue for the flight before it lands.
      _ = :sys.get_state(Nexo.Infra.SingleFlight)
      send(owner, :go)

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == {:ok, %{value: 42}, %{source: "test"}}))
      assert :counters.get(calls, 1) == 1

      # Now it is a hit, recorded as cached for meta.cached.
      Cache.reset_meta()
      assert {:ok, _, _} = Cache.subject(subject, :slow, compute, ttl: 60_000)
      assert %{cached: true} = Cache.take_meta()
      assert :counters.get(calls, 1) == 1
    end

    test "a failure is not stored; the last good answer is served while it lasts" do
      subject = %{type: :student, id: "st-#{System.unique_integer([:positive])}"}

      assert {:ok, :fresh, %{}} =
               Cache.subject(subject, :flaky, fn -> {:ok, :fresh, %{}} end, ttl: 1)

      # Expired (1 ms TTL) but kept as a fallback: the outage is hidden.
      Process.sleep(5)
      Cache.reset_meta()

      assert {:ok, :fresh, %{}} =
               Cache.subject(subject, :flaky, fn -> {:error, :unavailable} end, ttl: 1)

      assert %{cached: true} = Cache.take_meta()

      # A dead session is never hidden.
      assert {:error, :reauth_required} =
               Cache.subject(subject, :flaky, fn -> {:error, :reauth_required} end, ttl: 1)
    end

    test "logout drops the user's cached data and the next answer is fresh", %{conn: conn} do
      wipe(~w(students upstream_sessions refresh_tokens))
      body = conn |> login("E001", "ok") |> json_response(200)
      authed = put_req_header(conn, "authorization", "Bearer " <> body["data"]["access_token"])

      first = authed |> get("/terms") |> json_response(200)
      assert first["meta"]["cached"] == false
      assert is_binary(first["meta"]["fetched_at"])

      second = authed |> get("/terms") |> json_response(200)
      assert second["meta"]["cached"] == true
      assert second["meta"]["fetched_at"] == first["meta"]["fetched_at"]

      %{"_id" => id} = Mongo.find_one(Db.conn(), "students", %{code: "E001"})
      subject = %{type: :student, id: Db.id_to_string(id)}
      assert {:ok, _} = Cache.peek_subject(subject, :terms)

      assert authed |> post("/auth/logout") |> json_response(200)
      assert Cache.peek_subject(subject, :terms) == :miss

      body = conn |> login("E001", "ok") |> json_response(200)
      authed = put_req_header(conn, "authorization", "Bearer " <> body["data"]["access_token"])
      assert (authed |> get("/terms") |> json_response(200))["meta"]["cached"] == false
    end
  end

  describe "university sessions and Mongo" do
    test "a Mongo failure is :unavailable, never a request to log in again" do
      # BSON cannot encode this id, so the driver call fails like an outage.
      subject = %{type: :student, id: {:not, :encodable}}

      assert Sessions.get(subject) == {:error, :unavailable}

      assert Sessions.with_session(subject, :sigma, fn _ -> flunk("must not run") end) ==
               {:error, :unavailable}

      assert Sessions.put(subject, %{sigma: "tok"}) == {:error, :unavailable}
    end

    test "no stored session is still :reauth_required" do
      subject = %{type: :student, id: "none-#{System.unique_integer([:positive])}"}
      assert Sessions.get(subject) == %{}
      assert Sessions.with_session(subject, :sigma, fn _ -> :ok end) == {:error, :reauth_required}
    end
  end

  describe "outbound circuit breaker" do
    test "opens after consecutive failures and then fails fast without calling" do
      host = :"test_host_#{System.unique_integer([:positive])}"
      threshold = 8

      for _ <- 1..threshold do
        assert Guard.run(host, fn _opts -> {:error, %RuntimeError{message: "timeout"}} end) ==
                 {:error, %RuntimeError{message: "timeout"}}
      end

      assert Guard.circuit(host) == :open

      assert Guard.run(host, fn _ -> flunk("must not call while open") end) ==
               {:error, :circuit_open}
    end

    test "a 5xx counts as a failure and a success closes it again" do
      host = :"test_host_#{System.unique_integer([:positive])}"
      previous = Application.get_env(:nexo, :upstream_guard, [])

      # Open for 0 ms: the next call is the probe.
      Application.put_env(:nexo, :upstream_guard, Keyword.put(previous, :open_ms, 0))
      on_exit(fn -> Application.put_env(:nexo, :upstream_guard, previous) end)

      for _ <- 1..8, do: Guard.run(host, fn _ -> {:ok, %Req.Response{status: 503}} end)
      assert Guard.circuit(host) == :half_open

      assert Guard.run(host, fn _ -> {:ok, %Req.Response{status: 200}} end) ==
               {:ok, %Req.Response{status: 200}}

      assert Guard.circuit(host) == :closed
    end

    test "calls get the dedicated pool and a timeout within the request budget" do
      Nexo.Infra.Deadline.start(3_000)
      opts = Guard.req_options()
      Nexo.Infra.Deadline.clear()

      assert opts[:finch][:name] == Nexo.Upstream.Finch
      assert opts[:receive_timeout] <= 3_000
      assert Guard.req_options()[:receive_timeout] == 10_000
    end
  end
end
