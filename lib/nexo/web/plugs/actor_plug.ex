defmodule Nexo.Web.ActorPlug do
  @moduledoc """
  Identifica a quien pide, sea docente o estudiante.

  El directorio no distingue por tipo de cuenta —lo que decide es el acceso
  concedido, no si eres alumno o profesor—, así que necesita un plug que
  acepte ambos tokens y deje un actor uniforme en `:current_actor`.
  """
  import Plug.Conn
  alias Nexo.People.{Students, Teachers}
  alias Nexo.Security.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{type: type, id: id}} <- Auth.verify_access_token(token),
         %{} = actor <- load(type, id) do
      assign(conn, :current_actor, actor)
    else
      _ -> Nexo.Web.AuthPlug.unauthorized(conn)
    end
  end

  defp load(:teacher, id) do
    case Teachers.get_teacher(id) do
      nil ->
        nil

      teacher ->
        %{
          type: :teacher,
          code: teacher["sigma_code"],
          first_name: teacher["first_name"],
          last_name: teacher["last_name"]
        }
    end
  end

  defp load(:student, id) do
    case Students.get(id) do
      nil ->
        nil

      student ->
        %{
          type: :student,
          code: student["code"],
          first_name: student["first_name"],
          last_name: student["last_name"]
        }
    end
  end

  # Un apoderado no es un actor del directorio: su token no abre esta puerta,
  # y se le responde 401 como a cualquier desconocido.
  defp load(_type, _id), do: nil
end
