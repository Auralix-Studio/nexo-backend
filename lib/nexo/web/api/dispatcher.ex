defmodule Nexo.Web.Api.Dispatcher do
  @moduledoc """
  Runs every route-module request through the same chain, in this order:

    1. Security headers on every response.
    2. Per-IP rate limit, before any work, so floods are cut cheaply. It is
       high (`ip_per_minute`, 3000): a whole campus shares one NAT IP.
    3. Route lookup (`404` / `405`).
    4. Feature flag (`503` when switched off).
    5. App attestation: the request must come from the Nexo app (`401`).
    6. Authentication and subject type (`401` / `403`).
    7. Per-user and per-route rate limits (`429`). Public routes have no
       user: they get their own per-IP limit (`public_ip_per_minute`).
    8. Param whitelist and validation (`422`), always, also on
       authenticated routes; then the route's per-param limit (the login
       is limited per `user`, not per IP).
    9. The route's `handle/2`, within a time budget (`request_deadline_ms`,
       20 s, below the app's 25 s; see `Nexo.Infra.Deadline`), whose result
       is wrapped in the standard envelope. A crash answers `500` with the
       request id only.

  Mounted at the root of the API host, after the legacy `/api/v1` routes.
  There is no version prefix: one is added only when a breaking change needs
  two versions alive at once.
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

  alias Nexo.Infra.{Cache, Deadline, Flags, RateLimiter}
  alias Nexo.Integrations.Connections

  alias Nexo.People.{Guardians, Students, Teachers}

  alias Nexo.Security.{AppCheck, Auth}
  alias Nexo.Web.{ClientIp, SecurityHeaders}
  alias Nexo.Web.Api.{Params, Registry, Response}

  @default_limits [ip_per_minute: 3000, subject_per_minute: 120, public_ip_per_minute: 600]
  @default_deadline_ms 20_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = conn |> SecurityHeaders.put() |> assign(:client_ip, ClientIp.get(conn))

    with {:ok, conn} <- limit_ip(conn),
         {:ok, spec, path_params} <- route(conn),
         conn = tag_route(conn, spec),
         {:ok, conn} <- check_flag(conn, spec),
         {:ok, conn} <- attest(conn, spec),
         {:ok, conn} <- authenticate(conn, spec),
         {:ok, conn} <- limit_subject(conn, spec),
         {:ok, params} <- validate(conn, spec, path_params),
         {:ok, conn} <- limit_param(conn, spec, params) do
      execute(conn, spec, params)
    else
      {:halt, conn} -> conn
    end
  end

  # --- 2. IP rate limit -----------------------------------------------------

  defp limit_ip(conn) do
    case RateLimiter.hit({:ip, conn.assigns.client_ip}, limit(:ip_per_minute), 60) do
      :ok -> {:ok, conn}
      {:error, retry_after} -> {:halt, rate_limited(conn, retry_after)}
    end
  end

  # --- 3. Route -------------------------------------------------------------

  defp route(conn) do
    method = conn.method |> String.downcase() |> method_atom()

    case method && Registry.match(Registry.routes(), method, conn.path_info) do
      {:ok, spec, params} ->
        {:ok, spec, params}

      {:error, {:method_not_allowed, allowed}} ->
        allow = allowed |> Enum.map(&(&1 |> to_string() |> String.upcase())) |> Enum.join(", ")
        {:halt, conn |> put_resp_header("allow", allow) |> Response.error(:method_not_allowed)}

      _ ->
        {:halt, Response.error(conn, :not_found)}
    end
  end

  defp method_atom("get"), do: :get
  defp method_atom("post"), do: :post
  defp method_atom("put"), do: :put
  defp method_atom("patch"), do: :patch
  defp method_atom("delete"), do: :delete
  defp method_atom(_), do: nil

  defp tag_route(conn, spec) do
    Logger.metadata(api_route: spec.name)
    assign(conn, :api_route, spec)
  end

  # --- 4. Feature flag ------------------------------------------------------

  defp check_flag(conn, %{flag: nil}), do: {:ok, conn}

  defp check_flag(conn, %{flag: flag}) do
    if Flags.enabled?(flag),
      do: {:ok, conn},
      else: {:halt, Response.error(conn, :feature_disabled)}
  end

  # --- 5. App attestation ---------------------------------------------------

  defp attest(conn, %{attest: false}), do: {:ok, conn}

  defp attest(conn, _spec) do
    case AppCheck.check(first_header(conn, AppCheck.header())) do
      {:ok, claims} ->
        {:ok, assign(conn, :app_check, claims)}

      {:error, reason} ->
        Logger.warning("App Check rejected from #{conn.assigns.client_ip}: #{reason}")
        {:halt, Response.error(conn, :app_not_verified)}
    end
  end

  # --- 6. Authentication ----------------------------------------------------

  defp authenticate(conn, %{auth: :public}), do: {:ok, assign(conn, :current_subject, nil)}

  defp authenticate(conn, %{auth: :admin}) do
    configured = Application.get_env(:nexo, :admin_api_key)
    provided = first_header(conn, "x-admin-key")

    if is_binary(configured) and configured != "" and is_binary(provided) and
         Plug.Crypto.secure_compare(provided, configured) do
      {:ok, assign(conn, :current_subject, %{type: :admin, id: "admin", record: nil})}
    else
      {:halt, Response.error(conn, :unauthorized)}
    end
  end

  defp authenticate(conn, %{auth: :integration, scopes: needed}) do
    with "Bearer " <> token <- first_header(conn, "authorization") || "",
         %{} = grant <- Connections.verify_access(token) do
      if Enum.all?(needed, &(&1 in grant["scopes"])) do
        subject = %{
          type: :integration,
          id: Nexo.Infra.Db.id_to_string(grant["_id"]),
          student_id: grant["student_id"],
          client_id: grant["client_id"],
          scopes: grant["scopes"],
          record: grant
        }

        {:ok, assign(conn, :current_subject, subject)}
      else
        {:halt,
         Response.error(conn, :forbidden, message: "This app was not granted that access.")}
      end
    else
      _ -> {:halt, Response.error(conn, :unauthorized)}
    end
  end

  defp authenticate(conn, %{auth: allowed}) do
    with "Bearer " <> token <- first_header(conn, "authorization") || "",
         {:ok, %{type: type, id: id}} <- Auth.verify_access_token(token) do
      if type in allowed do
        case load_subject(type, id) do
          {:ok, record} ->
            {:ok, assign(conn, :current_subject, %{type: type, id: id, record: record})}

          # Mongo is failing: an outage, not a reason to log in again.
          {:error, _} ->
            {:halt, Response.error(conn, :upstream_unavailable)}

          nil ->
            {:halt, Response.error(conn, :unauthorized)}
        end
      else
        {:halt, Response.error(conn, :forbidden)}
      end
    else
      _ -> {:halt, Response.error(conn, :unauthorized)}
    end
  end

  # Student and teacher records are kept 30 s in memory (dropped when this
  # node updates them), so suspending a teacher takes effect within 30 s,
  # not when the token expires. Guardians are read every time: unlinking
  # one takes effect at once. `{:ok, record}`, `nil` or `{:error, _}`.
  defp load_subject(:teacher, id),
    do: Cache.subject_record(:teacher, id, fn -> Teachers.get_teacher(id) end)

  defp load_subject(:student, id),
    do: Cache.subject_record(:student, id, fn -> Students.get(id) end)

  defp load_subject(:guardian, id) do
    case Guardians.get(id) do
      %{} = guardian -> if Guardians.active?(guardian), do: {:ok, guardian}
      {:error, _} = error -> error
      _ -> nil
    end
  end

  # --- 7. Subject and route rate limits -------------------------------------

  defp limit_subject(conn, spec) do
    who = identity(conn)

    with :ok <- limit_who(who),
         :ok <- limit_route(spec, who) do
      {:ok, conn}
    else
      {:error, retry_after} -> {:halt, rate_limited(conn, retry_after)}
    end
  end

  defp limit_who({:ip, ip}),
    do: RateLimiter.hit({:public, ip}, limit(:public_ip_per_minute), 60)

  defp limit_who(who), do: RateLimiter.hit({:subject, who}, limit(:subject_per_minute), 60)

  defp limit_route(%{rate_limit: nil}, _who), do: :ok

  defp limit_route(%{rate_limit: {count, seconds}, name: name}, who),
    do: RateLimiter.hit({:route, name, who}, count, seconds)

  defp identity(%{assigns: %{current_subject: %{type: type, id: id}}}), do: {type, id}
  defp identity(conn), do: {:ip, conn.assigns.client_ip}

  # --- 8. Params ------------------------------------------------------------

  defp validate(conn, spec, path_params) do
    raw =
      conn.query_params
      |> merge_map(conn.body_params)
      |> Map.merge(path_params)

    case Params.validate(spec.params, raw) do
      {:ok, params} -> {:ok, params}
      {:error, details} -> {:halt, Response.error(conn, :invalid_params, details: details)}
    end
  end

  defp merge_map(base, %{} = extra), do: Map.merge(base, extra)
  defp merge_map(base, _), do: base

  defp limit_param(conn, %{param_rate_limit: nil}, _params), do: {:ok, conn}

  defp limit_param(conn, %{param_rate_limit: {param, count, seconds}, name: name}, params) do
    value = params |> Map.get(param) |> to_string() |> String.trim() |> String.downcase()

    case RateLimiter.hit({:param, name, value}, count, seconds) do
      :ok -> {:ok, conn}
      {:error, retry_after} -> {:halt, rate_limited(conn, retry_after)}
    end
  end

  # --- 9. Execute -----------------------------------------------------------

  defp execute(conn, spec, params) do
    # A kept-alive connection runs several requests in the same process.
    Cache.reset_meta()
    Deadline.start(Application.get_env(:nexo, :request_deadline_ms, @default_deadline_ms))
    run(conn, spec, params)
  after
    Deadline.clear()
    Cache.reset_meta()
  end

  defp run(conn, spec, params) do
    case spec.module.handle(conn, params) do
      %Plug.Conn{} = conn ->
        conn

      {:ok, data} ->
        Response.ok(conn, data)

      {:ok, status, data} when is_integer(status) ->
        Response.ok(conn, status, data)

      {:ok, data, %{} = meta} ->
        Response.ok(conn, 200, data, meta)

      {:error, code} when is_atom(code) ->
        Response.error(conn, code)

      {:error, status, code, message} ->
        Response.error(conn, code, status: status, message: message)
    end
  rescue
    exception ->
      # Arities only: a frame's arguments could hold a password or a token.
      stacktrace =
        Enum.map(__STACKTRACE__, fn
          {m, f, args, location} when is_list(args) -> {m, f, length(args), location}
          frame -> frame
        end)

      Logger.error(
        "API route #{spec.name} crashed: " <>
          Exception.format_banner(:error, exception, stacktrace) <>
          "\n" <> Exception.format_stacktrace(stacktrace)
      )

      Response.error(conn, :internal_error)
  end

  # --- Helpers --------------------------------------------------------------

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> Response.error(:rate_limited)
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp limit(key) do
    :nexo
    |> Application.get_env(:rate_limits, [])
    |> Keyword.get(key, Keyword.fetch!(@default_limits, key))
  end
end
