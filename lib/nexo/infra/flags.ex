defmodule Nexo.Infra.Flags do
  @moduledoc """
  Feature flags stored in MongoDB (`feature_flags`), switchable at runtime.

  Every API route has a flag named after it. A flag that was never set is
  on; turning it off makes the route answer `503 feature_disabled` within
  30 seconds on every node, without a deploy. Lookups are cached so a
  request does not pay a database round trip.

  If the database cannot be reached the flag reads as on (fail open): flags
  exist to switch features off on purpose, and an outage should not look
  like a decision. The lookup is not cached in that case, so it recovers by
  itself.
  """
  alias Nexo.Infra.{Cache, Db}
  alias Nexo.Security.Audit

  @collection "feature_flags"
  @ttl :timer.seconds(30)

  def collection, do: @collection

  def enabled?(name) when is_binary(name) do
    case Cache.fetch({:flag, name}, @ttl, fn -> lookup(name) end) do
      {:ok, enabled} -> enabled
      _ -> true
    end
  end

  defp lookup(name) do
    case Mongo.find_one(Db.conn(), @collection, %{name: name}) do
      nil -> {:ok, true}
      %{"enabled" => enabled} -> {:ok, enabled != false}
      {:error, _} = error -> error
      _ -> {:ok, true}
    end
  end

  @doc "Turns a flag on or off and records who did it."
  def set(name, enabled, actor, meta \\ %{})
      when is_binary(name) and is_boolean(enabled) do
    now = Db.now()

    result =
      Mongo.update_one(
        Db.conn(),
        @collection,
        %{name: name},
        %{"$set" => %{enabled: enabled, updated_at: now, updated_by: actor}},
        upsert: true
      )

    with {:ok, _} <- result do
      Cache.delete({:flag, name})

      Audit.log(
        :feature_flag_set,
        Map.merge(meta, %{actor: actor, target: name, enabled: enabled})
      )

      :ok
    end
  end

  @doc "Flags that were set explicitly (unset flags are on)."
  def list do
    Db.conn()
    |> Mongo.find(@collection, %{}, sort: %{name: 1})
    |> Enum.map(fn doc ->
      %{
        name: doc["name"],
        enabled: doc["enabled"] != false,
        updated_at: doc["updated_at"],
        updated_by: doc["updated_by"]
      }
    end)
  end
end
