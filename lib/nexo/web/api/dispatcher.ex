defmodule Nexo.Web.Api.Dispatcher do
  @moduledoc """
  Runs every route-module request through the same chain, in this order:

    1. Security headers on every response.
    2. Per-IP rate limit, before any work, so floods are cut cheaply.
    3. Route lookup (`404` / `405`).
    4. Feature flag (`503` when switched off).
    5. App attestation: the request must come from the Nexo app (`401`).
    6. Authentication and subject type (`401` / `403`).
    7. Per-user and per-route rate limits (`429`).
    8. Param whitelist and validation (`422`), always, also on
       authenticated routes.
    9. The route's `handle/2`, whose result is wrapped in the standard
       envelope. A crash answers `500` with the request id only.

  Mounted at the root of the API host, after the legacy `/api/v1` routes.
  There is no version prefix: one is added only when a breaking change needs
  two versions alive at once.
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

  alias Nexo.Infra.{Flags, RateLimiter}
  alias Nexo.Integrations.Connections

  alias Nexo.People.{Guardians, Students, Teachers}

  alias Nexo.Security.{AppCheck, Auth}
  alias Nexo.Web.{ClientIp, SecurityHeaders}
  alias Nexo.Web.Api.{Params, Registry, Response}

  @default_limits [ip_per_minute: 300, subject_per_minute: 120]

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
         {:ok, params} <- validate(conn, spec, path_params) do
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
          nil -> {:halt, Response.error(conn, :unauthorized)}
          record -> {:ok, assign(conn, :current_subject, %{type: type, id: id, record: record})}
        end
      else
        {:halt, Response.error(conn, :forbidden)}
      end
    else
      _ -> {:halt, Response.error(conn, :unauthorized)}
    end
  end

  # The record is reloaded on every request, so suspending a teacher or
  # unlinking a guardian takes effect at once, not when the token expires.
  defp load_subject(:teacher, id), do: Teachers.get_teacher(id)
  defp load_subject(:student, id), do: Students.get(id)

  defp load_subject(:guardian, id) do
    case Guardians.get(id) do
      %{} = guardian -> if Guardians.active?(guardian), do: guardian
      _ -> nil
    end
  end

  # --- 7. Subject and route rate limits -------------------------------------

  defp limit_subject(conn, spec) do
    who = identity(conn)

    with :ok <- RateLimiter.hit({:subject, who}, limit(:subject_per_minute), 60),
         :ok <- limit_route(spec, who) do
      {:ok, conn}
    else
      {:error, retry_after} -> {:halt, rate_limited(conn, retry_after)}
    end
  end

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

  # --- 9. Execute -----------------------------------------------------------

  defp execute(conn, spec, params) do
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
      Logger.error(
        "API route #{spec.name} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
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
