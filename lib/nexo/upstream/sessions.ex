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
  alias Nexo.Infra.{Cache, Db}
  alias Nexo.Security.Vault
  alias Nexo.Sigma
  alias Nexo.Upstream.Intranet

  @collection "upstream_sessions"
  @sources ~w(sigma intranet languages)a
  @memory_ttl :timer.seconds(45)

  @type subject :: %{type: atom(), id: String.t()}
  @type source :: :sigma | :intranet | :languages

  @doc """
  Replaces the stored sessions of `subject` with `sessions` (missing sources
  are dropped). `:ok`, or `{:error, :unavailable}` when Mongo fails.
  """
  def put(%{type: type, id: id} = subject, sessions) when is_map(sessions) do
    data =
      sessions
      |> Map.take(@sources)
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    stored = Map.new(data, fn {k, v} -> {Atom.to_string(k), v} end)

    result =
      safely(fn ->
        Mongo.update_one(
          Db.conn(),
          @collection,
          %{subject_type: to_string(type), subject_id: id},
          %{
            "$set" => %{
              data: %BSON.Binary{binary: Vault.encrypt(Jason.encode!(stored))},
              updated_at: Db.now()
            }
          },
          upsert: true
        )
      end)

    case result do
      {:ok, _} ->
        Cache.put(cache_key(subject), data, @memory_ttl)
        :ok

      _ ->
        Cache.delete(cache_key(subject))
        {:error, :unavailable}
    end
  end

  @doc """
  All stored sessions of `subject`, as `%{sigma: …, intranet: …, languages: …}`
  (`%{}` when there are none), or `{:error, :unavailable}` when Mongo
  fails: an outage must not look like a logged-out user.

  Decrypted sessions are kept in memory for #{div(@memory_ttl, 1000)} s; this
  node's writes update that copy.
  """
  def get(subject) do
    case Cache.get(cache_key(subject)) do
      {:ok, sessions} -> sessions
      :miss -> load(subject)
    end
  end

  defp load(%{type: type, id: id} = subject) do
    query = %{subject_type: to_string(type), subject_id: id}

    case safely(fn -> Mongo.find_one(Db.conn(), @collection, query) end) do
      {:error, _} ->
        {:error, :unavailable}

      document ->
        sessions = decode(document)
        Cache.put(cache_key(subject), sessions, @memory_ttl)
        sessions
    end
  end

  defp decode(document) do
    with %{"data" => %BSON.Binary{binary: blob}} <- document,
         {:ok, json} <- Vault.decrypt(blob),
         {:ok, data} <- Jason.decode(json) do
      for source <- @sources, value = data[Atom.to_string(source)], into: %{}, do: {source, value}
    else
      _ -> %{}
    end
  end

  def delete(%{type: type, id: id} = subject) do
    Cache.delete(cache_key(subject))

    safely(fn ->
      Mongo.delete_one(Db.conn(), @collection, %{subject_type: to_string(type), subject_id: id})
    end)

    Cache.delete(cache_key(subject))
    :ok
  end

  defp cache_key(%{type: type, id: id}), do: {:upstream_sessions, type, id}

  # The driver answers `{:error, _}`, but a checkout timeout can also raise.
  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Runs `fun` with the stored session for `source`.

  * no stored session, or `fun` reports `:session_expired` → the session is
    dropped and `{:error, :reauth_required}` is returned;
  * Mongo fails → `{:error, :unavailable}`, never a new login;
  * `fun` may return `{:ok, value, new_session}` (Intranet cookies rotate),
    which is saved before returning `{:ok, value}`.
  """
  def with_session(subject, source, fun, opts \\ []) when source in @sources do
    case get(subject) do
      {:error, _} = error ->
        error

      sessions ->
        case Map.get(sessions, source) do
          # `missing: :unavailable` for optional sources (the Language Center):
          # a session never opened is not a reason to log in again.
          nil -> {:error, Keyword.get(opts, :missing, :reauth_required)}
          session -> run(subject, source, session, fun)
        end
    end
  end

  defp run(subject, source, session, fun) do
    # The other sources are re-read before writing: parallel requests of
    # the same user must not undo each other's changes.
    case fun.(session) do
      {:ok, value, ^session} ->
        {:ok, value}

      {:ok, value, new_session} ->
        update(subject, &Map.put(&1, source, new_session))
        {:ok, value}

      {:error, :session_expired} ->
        update(subject, &Map.delete(&1, source))
        {:error, :reauth_required}

      other ->
        other
    end
  end

  # A failed write only loses rotated cookies; the answer is still good.
  defp update(subject, change) do
    case get(subject) do
      {:error, _} -> :ok
      sessions -> put(subject, change.(sessions))
    end
  end

  @doc "SIGMA `GET path` with the stored session: `{:ok, data}` or an error."
  def sigma_fetch(subject, path) do
    with_session(subject, :sigma, fn token ->
      with {:ok, data} <- Sigma.fetch(token, path), do: {:ok, data, token}
    end)
  end

  @doc "Intranet `POST path` with the stored cookies (rotated ones are saved)."
  def intranet_post(subject, path, form, referer),
    do: with_session(subject, :intranet, &Intranet.post(&1, path, form, referer))

  @doc "Intranet `GET path` with the stored cookies (rotated ones are saved)."
  def intranet_get(subject, path, referer),
    do: with_session(subject, :intranet, &Intranet.get(&1, path, referer))

  @doc "A source's state for `meta.sources`: `ok`, `reauth_required` or `unavailable`."
  def status({:ok, _}), do: "ok"
  def status({:ok, _, _}), do: "ok"
  def status({:error, :reauth_required}), do: "reauth_required"
  def status(_), do: "unavailable"

  @doc "The value of an `{:ok, value}` result, or `nil`."
  def value({:ok, value}), do: value
  def value(_), do: nil
end
