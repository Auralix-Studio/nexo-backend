defmodule Nexo.Integrations.Clients do
  @moduledoc """
  Third-party apps allowed to ask students for access ("Connect with Nexo").

  An administrator registers each app; only `active` apps can start a
  connection, and suspending one cuts every token it holds at the next
  request. Apps are public OAuth clients (no secret): they cannot keep one
  safe on a phone or in a browser, and the device flow does not need it,
  because the student approves inside the Nexo app.
  """
  alias Nexo.Infra.Db
  alias Nexo.Security.Audit

  @collection "integration_clients"
  @statuses ~w(active suspended)

  def collection, do: @collection
  def statuses, do: @statuses

  def register(name, opts \\ []) when is_binary(name) do
    client_id = "nxc_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

    doc = %{
      client_id: client_id,
      name: name,
      website: Keyword.get(opts, :website),
      status: "active",
      created_at: Db.now()
    }

    {:ok, _} = Mongo.insert_one(Db.conn(), @collection, doc)
    Audit.log(:integration_client_registered, %{actor: "admin", target: client_id, name: name})
    {:ok, public(doc)}
  end

  def get(client_id) when is_binary(client_id) do
    case Mongo.find_one(Db.conn(), @collection, %{client_id: client_id}) do
      nil -> nil
      doc -> public(doc)
    end
  end

  def active(client_id) do
    case get(client_id) do
      %{status: "active"} = client -> client
      _ -> nil
    end
  end

  def list do
    Db.conn()
    |> Mongo.find(@collection, %{}, sort: %{created_at: -1})
    |> Enum.map(&public/1)
  end

  def set_status(client_id, status) when status in @statuses do
    case Mongo.update_one(Db.conn(), @collection, %{client_id: client_id}, %{
           "$set" => %{status: status}
         }) do
      {:ok, %{matched_count: 1}} ->
        Audit.log(:integration_client_status, %{actor: "admin", target: client_id, status: status})

        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp public(doc) do
    %{
      client_id: doc["client_id"] || doc[:client_id],
      name: doc["name"] || doc[:name],
      website: doc["website"] || doc[:website],
      status: doc["status"] || doc[:status],
      created_at: doc["created_at"] || doc[:created_at]
    }
  end
end
