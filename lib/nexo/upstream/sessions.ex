defmodule Nexo.Upstream.Sessions do
  @moduledoc """
  The university sessions of each Nexo user, kept on the server so the app
  only talks to the Nexo API.

  Stored encrypted (`Nexo.Security.Vault`) in `upstream_sessions`: the SIGMA
  token, the Intranet cookies and the Language Center token. **Passwords are
  never stored.** When a university session expires, the call answers
  `:reauth_required`; the app then logs in again with the credentials it
  keeps in the device's secure storage, and the request is retried.
  """
  alias Nexo.Infra.Db
  alias Nexo.Security.Vault

  @collection "upstream_sessions"
  @sources ~w(sigma intranet languages)a

  def collection, do: @collection

  @type subject :: %{type: atom(), id: String.t()}
  @type source :: :sigma | :intranet | :languages

  @doc "Replaces the stored sessions of `subject` with `sessions` (missing sources are dropped)."
  def put(%{type: type, id: id}, sessions) when is_map(sessions) do
    data =
      sessions
      |> Map.take(@sources)
      |> Map.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    {:ok, _} =
      Mongo.update_one(
        Db.conn(),
        @collection,
        %{subject_type: to_string(type), subject_id: id},
        %{
          "$set" => %{
            data: %BSON.Binary{binary: Vault.encrypt(Jason.encode!(data))},
            updated_at: Db.now()
          }
        },
        upsert: true
      )

    :ok
  end

  @doc "All stored sessions of `subject`, as `%{sigma: …, intranet: …, languages: …}`."
  def get(%{type: type, id: id}) do
    with %{"data" => %BSON.Binary{binary: blob}} <-
           Mongo.find_one(Db.conn(), @collection, %{
             subject_type: to_string(type),
             subject_id: id
           }),
         {:ok, json} <- Vault.decrypt(blob),
         {:ok, data} <- Jason.decode(json) do
      for source <- @sources, value = data[Atom.to_string(source)], into: %{}, do: {source, value}
    else
      _ -> %{}
    end
  end

  def delete(%{type: type, id: id}) do
    Mongo.delete_one(Db.conn(), @collection, %{subject_type: to_string(type), subject_id: id})
    :ok
  end

  @doc """
  Runs `fun` with the stored session for `source`.

  * no stored session, or `fun` reports `:session_expired` → the session is
    dropped and `{:error, :reauth_required}` is returned;
  * `fun` may return `{:ok, value, new_session}` (Intranet cookies rotate),
    which is saved before returning `{:ok, value}`.
  """
  def with_session(subject, source, fun, opts \\ []) when source in @sources do
    sessions = get(subject)

    case Map.get(sessions, source) do
      # `missing: :unavailable` for optional sources (the Language Center):
      # a session never opened is not a reason to log in again.
      nil ->
        {:error, Keyword.get(opts, :missing, :reauth_required)}

      session ->
        case fun.(session) do
          {:ok, value, ^session} ->
            {:ok, value}

          {:ok, value, new_session} ->
            put(subject, Map.put(sessions, source, new_session))
            {:ok, value}

          {:error, :session_expired} ->
            put(subject, Map.delete(sessions, source))
            {:error, :reauth_required}

          other ->
            other
        end
    end
  end
end
