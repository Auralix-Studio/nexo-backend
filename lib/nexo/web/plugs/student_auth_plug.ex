defmodule Nexo.Web.StudentAuthPlug do
  @moduledoc "Igual que `Nexo.Web.AuthPlug` pero para tokens de estudiante."
  import Plug.Conn
  alias Nexo.People.Students
  alias Nexo.Security.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{type: :student, id: id}} <- Auth.verify_access_token(token),
         %{} = student <- Students.get(id) do
      assign(conn, :current_student, student)
    else
      _ -> Nexo.Web.AuthPlug.unauthorized(conn)
    end
  end
end
