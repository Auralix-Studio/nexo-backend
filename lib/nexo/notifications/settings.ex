defmodule Nexo.Notifications.Settings do
  @moduledoc """
  Per-user notification preferences (collection `notification_settings`).
  Grade notifications are on by default: the document is created with
  `grades: true` the first time a device registers.
  """
  alias Nexo.Infra.Db

  @collection "notification_settings"

  defp key(%{type: type, id: id}), do: %{subject_type: to_string(type), subject_id: id}

  @doc "`%{grades: boolean}`; defaults when nothing was stored."
  def get(subject) do
    case Mongo.find_one(Db.conn(), @collection, key(subject)) do
      %{"grades" => grades} -> %{grades: grades != false}
      _ -> %{grades: true}
    end
  end

  @doc "Creates the defaults if missing (first device registration)."
  def ensure(subject) do
    update(subject, %{"$setOnInsert" => %{grades: true, created_at: Db.now()}})
  end

  def put_grades(subject, enabled) when is_boolean(enabled) do
    update(subject, %{
      "$set" => %{grades: enabled, updated_at: Db.now()},
      "$setOnInsert" => %{created_at: Db.now()}
    })
  end

  defp update(subject, change) do
    {:ok, _} = Mongo.update_one(Db.conn(), @collection, key(subject), change, upsert: true)
    :ok
  end
end
