defmodule Nexo.Web.SecurityHeaders do
  @moduledoc """
  Hardening headers for JSON API responses.

  The API serves no pages, so the content policy forbids everything: if a
  response were ever opened in a browser, nothing in it could run, load or
  be framed. Responses are never cached, since they carry personal data.
  """
  @behaviour Plug
  import Plug.Conn

  @headers [
    {"cache-control", "no-store"},
    {"pragma", "no-cache"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "no-referrer"},
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'"},
    {"cross-origin-resource-policy", "same-origin"},
    {"strict-transport-security", "max-age=63072000; includeSubDomains"},
    {"permissions-policy", "camera=(), microphone=(), geolocation=()"}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: put(conn)

  def put(conn), do: Enum.reduce(@headers, conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)
end
