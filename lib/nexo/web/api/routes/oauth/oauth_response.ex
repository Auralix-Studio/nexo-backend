defmodule Nexo.Web.Api.Routes.OAuth.OAuthResponse do
  @moduledoc "OAuth endpoints answer in the standard OAuth shape, not the API envelope."
  import Plug.Conn

  def ok(conn, body), do: reply(conn, 200, body)

  def error(conn, code) do
    status = if code == :invalid_client, do: 401, else: 400
    reply(conn, status, %{error: code})
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
