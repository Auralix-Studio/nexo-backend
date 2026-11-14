defmodule Nexo.Web.AppCheckPlug do
  @moduledoc """
  Rejects requests to the legacy `/api/v1` routes that do not come from the official Nexo app (see
  `Nexo.Security.AppCheck`). The route modules run the same check inside their dispatcher,
  per route.
  """
  @behaviour Plug
  import Plug.Conn
  require Logger
  alias Nexo.Security.AppCheck

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    token =
      case get_req_header(conn, AppCheck.header()) do
        [value | _] -> value
        [] -> nil
      end

    case AppCheck.check(token) do
      {:ok, claims} ->
        assign(conn, :app_check, claims)

      {:error, reason} ->
        Logger.warning(
          "App Check rejected #{conn.method} #{conn.request_path} " <>
            "from #{Nexo.Web.ClientIp.get(conn)}: #{reason}"
        )

        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "app_not_verified"})
        |> halt()
    end
  end
end
