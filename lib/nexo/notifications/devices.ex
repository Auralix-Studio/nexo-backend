defmodule Nexo.Notifications.Devices do
  @moduledoc """
  Push tokens of the users' phones (collection `devices`).

  One document per FCM token: a phone that logs in with another account
  moves its token to that account. Tokens are removed when the user logs
  out, unregisters the device or FCM reports them as dead.
  """
  alias Nexo.Infra.Db

  @collection "devices"
  @platforms ~w(android ios web)

  def platforms, do: @platforms

  @doc "Registers (or moves) `token` to `subject` and refreshes `last_seen`."
  def register(%{type: type, id: id}, token, platform)
      when is_binary(token) and platform in @platforms do
    now = Db.now()

    {:ok, _} =
      Mongo.update_one(
        Db.conn(),
        @collection,
        %{token: token},
        %{
          "$set" => %{
            subject_type: to_string(type),
            subject_id: id,
            platform: platform,
            last_seen: now
          },
          "$setOnInsert" => %{created_at: now}
        },
        upsert: true
      )

    :ok
  end

  @doc "Removes `token` if it belongs to `subject`."
  def unregister(%{type: type, id: id}, token) when is_binary(token) do
    {:ok, _} =
      Mongo.delete_one(Db.conn(), @collection, %{
        token: token,
        subject_type: to_string(type),
        subject_id: id
      })

    :ok
  end

  @doc "Removes every device of `subject` (logout)."
  def delete_all(%{type: type, id: id}) do
    {:ok, _} =
      Mongo.delete_many(Db.conn(), @collection, %{subject_type: to_string(type), subject_id: id})

    :ok
  end

  @doc "Removes a token FCM no longer accepts, whoever owns it."
  def forget(token) when is_binary(token) do
    {:ok, _} = Mongo.delete_one(Db.conn(), @collection, %{token: token})
    :ok
  end

  def tokens(%{type: type, id: id}) do
    Db.conn()
    |> Mongo.find(@collection, %{subject_type: to_string(type), subject_id: id},
      projection: %{token: 1}
    )
    |> Enum.map(& &1["token"])
  end

  def count(%{type: type, id: id}) do
    case Mongo.count_documents(Db.conn(), @collection, %{
           subject_type: to_string(type),
           subject_id: id
         }) do
      {:ok, n} -> n
      _ -> 0
    end
  end
end
