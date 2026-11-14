defmodule Nexo.Security.Audit do
  @moduledoc """
  Audit log (collection `audit_log`): every sensitive action (login, a
  student's record read, a grade written) with actor, target, IP and time.
  Peru's Law 29733 requires showing who accessed what.
  """
  alias Nexo.Infra.Db

  @collection "audit_log"

  def log(action, attrs \\ %{}) do
    doc =
      attrs
      |> Map.new()
      |> Map.merge(%{action: to_string(action), inserted_at: Db.now()})

    Mongo.insert_one(Db.conn(), @collection, doc)
  end

  def recent(limit \\ 100) do
    Db.conn()
    |> Mongo.find(@collection, %{}, sort: %{inserted_at: -1}, limit: limit)
    |> Enum.to_list()
  end
end
