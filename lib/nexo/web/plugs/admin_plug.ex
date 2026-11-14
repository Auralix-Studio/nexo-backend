defmodule Nexo.Web.AdminPlug do
  @moduledoc """
  Autenticación de administración para el piloto: cabecera `x-admin-key`
  comparada en tiempo constante contra la clave configurada. Si no hay clave
  configurada, el área admin queda cerrada.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    configured = Application.get_env(:nexo, :admin_api_key)

    with true <- is_binary(configured) and configured != "",
         [provided] <- get_req_header(conn, "x-admin-key"),
         true <- Plug.Crypto.secure_compare(provided, configured) do
      conn
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "admin_no_autorizado"})
        |> halt()
    end
  end
end
