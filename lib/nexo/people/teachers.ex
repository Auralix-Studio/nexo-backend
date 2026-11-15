defmodule Nexo.People.Teachers do
  @moduledoc """
  Teachers (collection `teachers`), created on their first login.

  A record starts `"pendiente"`, or `"autorizado"` when its code is listed in
  `AUTHORIZED_TEACHERS`; the status is shown in `GET /me`. Section scoping is
  checked on every request (`Nexo.Teaching.Sections`), not here.
  """
  alias Nexo.Infra.{Cache, Db}

  @collection "teachers"

  def get_teacher(id) when is_binary(id) do
    case Db.parse_id(id) do
      {:ok, oid} -> Mongo.find_one(Db.conn(), @collection, %{_id: oid})
      :error -> nil
    end
  end

  def get_teacher_by_code(sigma_code) do
    Mongo.find_one(Db.conn(), @collection, %{sigma_code: sigma_code})
  end

  @doc "Codes (DNI or SIGMA code) authorized without approval: `AUTHORIZED_TEACHERS`, comma separated."
  def preauthorized_codes do
    :nexo
    |> Application.get_env(:authorized_teachers, "")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def preauthorized?(code), do: code in preauthorized_codes()

  @doc """
  Registers the teacher on the first login (`"pendiente"`, or `"autorizado"`
  when preauthorized); later logins refresh the name when SIGMA sends one.
  """
  def upsert_teacher_from_sigma(%{code: code} = profile) do
    now = Db.now()
    preauthorized = preauthorized?(code)

    case get_teacher_by_code(code) do
      nil ->
        doc = %{
          "sigma_code" => code,
          "first_name" => profile.first_name,
          "last_name" => profile.last_name,
          "status" => if(preauthorized, do: "autorizado", else: "pendiente"),
          "authorized_at" => if(preauthorized, do: now),
          "authorized_by" => if(preauthorized, do: "preautorizado"),
          "inserted_at" => now,
          "updated_at" => now
        }

        with {:ok, %{inserted_id: id}} <- Mongo.insert_one(Db.conn(), @collection, doc) do
          {:ok, Map.put(doc, "_id", id)}
        end

      %{} = teacher ->
        updates = %{
          "first_name" => presence(profile.first_name) || teacher["first_name"],
          "last_name" => presence(profile.last_name) || teacher["last_name"],
          "updated_at" => now
        }

        # Preauthorization only promotes a pending teacher, never a suspended one.
        updates =
          if preauthorized and teacher["status"] == "pendiente" do
            Map.merge(updates, %{
              "status" => "autorizado",
              "authorized_at" => now,
              "authorized_by" => "preautorizado"
            })
          else
            updates
          end

        apply_updates(teacher, updates)
    end
  end

  defp apply_updates(%{"_id" => id} = teacher, updates) do
    with {:ok, _} <-
           Mongo.update_one(Db.conn(), @collection, %{_id: id}, %{"$set" => updates}) do
      Cache.forget_subject_record(:teacher, Db.id_to_string(id))
      {:ok, Map.merge(teacher, updates)}
    end
  end

  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
end
