defmodule Nexo.Web.TeacherController do
  use Nexo.Web, :controller

  alias Nexo.Web.AuthController

  @doc "Estado del docente autenticado (la app decide qué mostrar según `estado`)."
  def me(conn, _params) do
    json(conn, %{teacher: AuthController.teacher_view(conn.assigns.current_teacher)})
  end
end
