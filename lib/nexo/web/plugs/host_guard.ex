defmodule Nexo.Web.HostGuard do
  @moduledoc """
  Answers only requests addressed to the API's own domain.

  Scanners usually reach a server through its IP or a default cloud name
  (`*.azurecontainerapps.io`) rather than the public domain. With
  `:allowed_hosts` set (`ALLOWED_HOSTS` in production, e.g.
  `api.nexo.aurx.pro`), any other `Host` gets `421 Misdirected Request`
  and nothing else. `/health` stays reachable on any host, because the
  platform's health probes call it by internal address.

  With no allowed hosts configured the guard does nothing, so a first
  deployment can be tested on its default address before the domain is
  bound.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Application.get_env(:nexo, :allowed_hosts, []) do
      [] ->
        conn

      allowed ->
        if String.downcase(conn.host) in allowed do
          conn
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(421, ~s({"ok":false,"error":{"code":"misdirected_request"}}))
          |> halt()
        end
    end
  end
end
