defmodule Nexo.Web.AuthPlug do
  @moduledoc """
  Exige `Authorization: Bearer <access token>` de un **docente** y lo carga
  desde la base en cada petición: un docente suspendido pierde acceso al
  instante aunque su token siga vigente.
  """
  import Plug.Conn
  alias Nexo.People.Teachers
  alias Nexo.Security.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{type: :teacher, id: id}} <- Auth.verify_access_token(token),
         %{} = teacher <- Teachers.get_teacher(id) do
      assign(conn, :current_teacher, teacher)
    else
      _ -> Nexo.Web.AuthPlug.unauthorized(conn)
    end
  end

  def unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "no_autenticado"})
    |> halt()
  end
end
