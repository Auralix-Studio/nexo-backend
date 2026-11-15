defmodule Nexo.Notifications.GradeAlerts do
  @moduledoc """
  Grade notifications driven by events, not polling: when a teacher saves
  grades through Nexo and SIGMA confirms them, each affected student who has
  the app with notifications on gets a push at once ("Base de Datos ·
  Unidad 2 · Evidencia de conocimiento: 15").

  Costs nothing while nobody writes grades: no periodic reads of the
  university and no background logins. Grades entered outside Nexo are
  still detected by the app when it opens (it compares with what it saw).
  Grades are never stored here.
  """
  require Logger
  alias Nexo.Infra.{Cache, Db}
  alias Nexo.Notifications.{Push, Settings}
  alias Nexo.People.Students

  @doc "Notifies, in the background, every student in `changed` (`[%{student, value, unit, type}]`)."
  def saved(_section, []), do: :ok
  def saved(_section, nil), do: :ok

  def saved(section, changed) do
    Task.start(fn ->
      forget_grades(changed)
      if Push.enabled?(), do: deliver(section, changed)
    end)

    :ok
  end

  # The push makes the student open the app: their cached grades (this
  # node's) must not hide the new ones.
  @doc false
  def forget_grades(changed) do
    for code <- changed |> Enum.map(& &1.student) |> Enum.uniq(),
        %{"_id" => id} <- [Students.get_by_code(code)] do
      subject = %{type: :student, id: Db.id_to_string(id)}
      Cache.invalidate_subject(subject, {:grade_courses, :_})
      Cache.invalidate_subject(subject, {:grade_course, :_, :_})
      Cache.invalidate_subject(subject, :grades_summary)
    end

    :ok
  rescue
    error -> Logger.warning("grade cache invalidation failed: #{Exception.message(error)}")
  end

  @doc false
  def deliver(section, changed) do
    Enum.each(changed, fn item ->
      with %{"_id" => id} <- Students.get_by_code(item.student),
           subject = %{type: :student, id: Db.id_to_string(id)},
           %{grades: true} <- Settings.get(subject) do
        Push.deliver(subject, Push.grade(section, item))
      end
    end)
  rescue
    error -> Logger.warning("grade alerts failed: #{Exception.message(error)}")
  end
end
