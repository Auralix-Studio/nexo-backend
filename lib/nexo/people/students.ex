defmodule Nexo.People.Students do
  @moduledoc """
  Minimal student records (collection `students`): code and name, enough to
  identify who logs in. Grades, payments and schedule are read live from the
  university, never stored here.
  """
  alias Nexo.Infra.{Cache, Db}

  @collection "students"

  def get(id) when is_binary(id) do
    case Db.parse_id(id) do
      {:ok, oid} -> Mongo.find_one(Db.conn(), @collection, %{_id: oid})
      :error -> nil
    end
  end

  def get_by_code(code), do: Mongo.find_one(Db.conn(), @collection, %{code: code})

  def upsert_from_sigma(%{code: code} = profile) do
    now = Db.now()

    case get_by_code(code) do
      nil ->
        doc = %{
          "code" => code,
          "first_name" => profile.first_name,
          "last_name" => profile.last_name,
          "inserted_at" => now,
          "updated_at" => now
        }

        with {:ok, %{inserted_id: id}} <- Mongo.insert_one(Db.conn(), @collection, doc) do
          {:ok, Map.put(doc, "_id", id)}
        end

      %{"_id" => id} = student ->
        updates = %{
          "first_name" => profile.first_name,
          "last_name" => profile.last_name,
          "updated_at" => now
        }

        with {:ok, _} <-
               Mongo.update_one(Db.conn(), @collection, %{_id: id}, %{"$set" => updates}) do
          Cache.forget_subject_record(:student, Db.id_to_string(id))
          {:ok, Map.merge(student, updates)}
        end
    end
  end
end
