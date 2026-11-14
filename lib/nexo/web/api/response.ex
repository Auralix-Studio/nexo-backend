defmodule Nexo.Web.Api.Response do
  @moduledoc """
  The one response shape of the route modules.

      {"ok": true, "data": ...}
      {"ok": false, "error": {"code": "...", "message": "...", "details": ...}, "request_id": "..."}

  Errors always carry a real HTTP status, never `200` with a failure flag,
  and never an internal detail such as a stack trace or a query.
  """
  import Plug.Conn

  @messages %{
    bad_request: "The request is not valid.",
    unauthorized: "Authentication is required.",
    app_not_verified: "This API only answers the official Nexo app.",
    forbidden: "You do not have access to this resource.",
    not_found: "The resource does not exist.",
    method_not_allowed: "This method is not allowed on this resource.",
    conflict: "The request conflicts with the current state.",
    invalid_params: "Some parameters are not valid.",
    rate_limited: "Too many requests. Try again later.",
    internal_error: "Something went wrong on our side.",
    feature_disabled: "This feature is temporarily unavailable.",
    reauth_required: "The university session expired. Log in again.",
    invalid_credentials: "The user or password is not correct.",
    upstream_unavailable: "The university systems are not answering. Try again later."
  }

  @statuses %{
    bad_request: 400,
    unauthorized: 401,
    app_not_verified: 401,
    forbidden: 403,
    not_found: 404,
    method_not_allowed: 405,
    conflict: 409,
    invalid_params: 422,
    rate_limited: 429,
    internal_error: 500,
    feature_disabled: 503,
    reauth_required: 401,
    invalid_credentials: 401,
    upstream_unavailable: 503
  }

  def status_for(code) when is_atom(code), do: Map.get(@statuses, code, 400)
  def message_for(code) when is_atom(code), do: Map.get(@messages, code, "The request failed.")

  def ok(conn, status \\ 200, data, meta \\ nil) do
    body = %{ok: true, data: data}
    send_json(conn, status, if(meta, do: Map.put(body, :meta, meta), else: body))
  end

  def error(conn, code, opts \\ []) when is_atom(code) or is_binary(code) do
    status = Keyword.get_lazy(opts, :status, fn -> status_for(as_atom(code)) end)
    message = Keyword.get_lazy(opts, :message, fn -> message_for(as_atom(code)) end)

    error =
      %{code: to_string(code), message: message}
      |> maybe_put(:details, Keyword.get(opts, :details))

    send_json(conn, status, %{ok: false, error: error, request_id: request_id(conn)})
  end

  defp as_atom(code) when is_atom(code), do: code
  defp as_atom(_code), do: :bad_request

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end
end
