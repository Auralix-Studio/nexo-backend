defmodule Nexo.Web.GuardianAuthPlug do
  @moduledoc """
  Exige un token de apoderado y lo recarga en cada petición: revocar el
  vínculo corta el acceso al instante, sin esperar a que caduque el token.
  """
  import Plug.Conn
  alias Nexo.People.Guardians
  alias Nexo.Security.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{type: :guardian, id: id}} <- Auth.verify_access_token(token),
         %{} = guardian <- Guardians.get(id),
         true <- Guardians.active?(guardian) do
      assign(conn, :current_guardian, guardian)
    else
      _ -> Nexo.Web.AuthPlug.unauthorized(conn)
    end
  end
end
