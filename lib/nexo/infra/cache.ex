defmodule Nexo.Infra.Cache do
  @moduledoc """
  In-memory cache with per-entry TTL, backed by a public ETS table.

  Reads and writes go straight to ETS from the caller's process; the
  GenServer only owns the table and sweeps expired entries once a minute.
  Expiry uses monotonic time, so a wall-clock change cannot resurrect or
  kill entries early.

  Misses go through `Nexo.Infra.SingleFlight`: while one caller computes a
  key, the others wait for its result instead of repeating the work.

  ## University data

  `subject/4` and `shared/3` cache what the university returns, per user
  (`{:subject, {type, id}, name}`) or for everyone (`{:shared, name}`):

    * only complete results are stored (`:cache_if`, by default any `ok`);
    * an entry outlives its TTL by `:stale_ms` (default 1 h) as a fallback:
      when the university fails (not a dead session), the last good answer
      is served instead of the error;
    * the request process records whether its answer came from the cache
      and when it was fetched, for `meta.cached` and `meta.fetched_at`
      (`take_meta/0`). Only the outermost lookups of the request process
      count; lookups nested in them or made from tasks do not.

  `invalidate_subject/1` drops every entry of a user (logout, login). The
  table is capped (`:cache_max_bytes`, default 200 MB): above it the sweep
  drops the stale fallbacks first, then everything.
  """
  use GenServer
  require Logger

  alias Nexo.Infra.{Deadline, SingleFlight}

  @table :nexo_cache
  @sweep_every :timer.minutes(1)
  @stale_ms :timer.hours(1)
  @max_bytes 200 * 1024 * 1024
  @meta_key :nexo_cache_meta
  @depth_key :nexo_cache_depth
  # A caller waits for someone else's computation at most this long (and
  # never past its request's budget), then computes on its own.
  @flight_wait_ms 25_000

  # Source states that still make a complete answer.
  @fine_states ["ok", "not_needed", "not_applicable", "no_access"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, value}` for a live entry, `:miss` otherwise."
  def get(key) do
    case lookup(key) do
      {:fresh, value, _fetched_at} -> {:ok, value}
      _ -> :miss
    end
  end

  @doc "Stores `value` under `key` for `ttl_ms` milliseconds (plus `stale_ms` as a fallback)."
  def put(key, value, ttl_ms, stale_ms \\ 0) when is_integer(ttl_ms) and ttl_ms > 0 do
    now = now()
    :ets.insert(@table, {key, value, now + ttl_ms, now + ttl_ms + stale_ms, DateTime.utc_now()})
    :ok
  end

  @doc "Stores only when no live entry exists. Returns `true` if it stored."
  def put_new(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    case get(key) do
      {:ok, _} -> false
      :miss -> put(key, value, ttl_ms) == :ok
    end
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns the cached value or computes it with `fun`.

  `fun` returns `{:ok, value}` to cache it, or anything else to pass the
  result through uncached (so a failed lookup is retried next time).
  Concurrent misses of the same key run `fun` once.
  """
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    with :miss <- get(key) do
      {_, result} =
        SingleFlight.run({__MODULE__, key}, fn ->
          with :miss <- get(key) do
            case fun.() do
              {:ok, value} ->
                put(key, value, ttl_ms)
                {:ok, value}

              other ->
                other
            end
          end
        end)

      result
    end
  end

  @record_ttl :timer.seconds(30)

  @doc """
  The account record of a subject (`load` reads it from Mongo), kept
  #{div(@record_ttl, 1000)} s so each request does not pay a database round
  trip. Only found records are kept; `load`'s other answers (`nil`,
  `{:error, _}`) pass through.
  """
  def subject_record(type, id, load) when is_function(load, 0) do
    key = {:subject_record, type, id}

    with :miss <- get(key) do
      case load.() do
        %{} = record ->
          put(key, record, @record_ttl)
          {:ok, record}

        other ->
          other
      end
    end
  end

  @doc "Drops the kept record of a subject (its account changed)."
  def forget_subject_record(type, id), do: delete({:subject_record, type, id})

  # --- University data --------------------------------------------------------------------

  @doc """
  A result of the university for `subject`, cached under `name`.

  `fun` returns the module's usual result (`{:ok, data, meta}`, `{:error,
  reason}`…), which is returned as is. Options:

    * `:ttl` (required) — milliseconds, or a function of the result;
    * `:cache_if` — which results are stored (default `ok?/1`);
    * `:stale_ms` — how long an expired entry stays as a fallback.
  """
  def subject(%{type: type, id: id}, name, fun, opts),
    do: cached({:subject, {type, id}, name}, fun, opts)

  @doc "Like `subject/4` for data that is the same for every user."
  def shared(name, fun, opts), do: cached({:shared, name}, fun, opts)

  @doc "The live cached result of `subject` under `name`, or `:miss`. Not recorded in the meta."
  def peek_subject(%{type: type, id: id}, name), do: get({:subject, {type, id}, name})

  @doc "Drops every cached result of `subject`."
  def invalidate_subject(%{type: type, id: id}) do
    :ets.match_delete(@table, {{:subject, {type, id}, :_}, :_, :_, :_, :_})
    :ok
  end

  @doc "Drops the cached results of `subject` under `name`, a match pattern (`{:grades, :_}`)."
  def invalidate_subject(%{type: type, id: id}, name) do
    :ets.match_delete(@table, {{:subject, {type, id}, name}, :_, :_, :_, :_})
    :ok
  end

  @doc """
  Whether this request's answer came from the cache, and when it was
  fetched: `%{cached: boolean, fetched_at: DateTime}`. Clears the record.
  """
  def take_meta do
    case Process.delete(@meta_key) do
      [_ | _] = records ->
        %{
          cached: Enum.all?(records, & &1.cached),
          fetched_at: records |> Enum.map(& &1.fetched_at) |> Enum.min(DateTime)
        }

      _ ->
        %{cached: false, fetched_at: DateTime.utc_now()}
    end
  end

  @doc "Forgets what this process recorded (a new request on a kept-alive connection)."
  def reset_meta do
    Process.delete(@meta_key)
    Process.delete(@depth_key)
    :ok
  end

  @doc "`{:ok, _}` and `{:ok, _, _}` results."
  def ok?({:ok, _}), do: true
  def ok?({:ok, _, _}), do: true
  def ok?(_), do: false

  @doc "An `{:ok, data, sources}` result whose sources all answered."
  def sources_ok?({:ok, _data, %{} = sources}),
    do: Enum.all?(Map.values(sources), &(&1 in @fine_states))

  def sources_ok?(_), do: false

  defp cached(key, fun, opts) do
    outer? = Process.get(@depth_key, 0) == 0

    if enabled?() do
      {result, cached?, fetched_at} = nested(fn -> lookup_or_compute(key, fun, opts) end)
      if outer?, do: record(cached?, fetched_at)
      result
    else
      result = nested(fun)
      if outer?, do: record(false, DateTime.utc_now())
      result
    end
  end

  defp lookup_or_compute(key, fun, opts) do
    case lookup(key) do
      {:fresh, result, fetched_at} ->
        {result, true, fetched_at}

      previous ->
        {how, %{result: result} = outcome} =
          SingleFlight.run(
            {__MODULE__, key},
            fn -> compute(key, fun, opts) end,
            Deadline.cap(@flight_wait_ms)
          )

        cond do
          # Another user's dead session says nothing about this caller's.
          how == :shared and reauth?(result) and match?({:shared, _}, key) ->
            %{result: own} = outcome = compute(key, fun, opts)
            {own, outcome.from_cache?, outcome.fetched_at}

          outcome.stored? or reauth?(result) ->
            {result, outcome.from_cache?, outcome.fetched_at}

          true ->
            fallback(result, previous)
        end
    end
  end

  defp compute(key, fun, opts) do
    # Someone may have stored it while this caller queued for the flight.
    case lookup(key) do
      {:fresh, result, fetched_at} ->
        %{result: result, fetched_at: fetched_at, from_cache?: true, stored?: true}

      _ ->
        result = fun.()
        stored? = Keyword.get(opts, :cache_if, &ok?/1).(result) == true

        if stored? do
          ttl = ttl(Keyword.fetch!(opts, :ttl), result)
          put(key, result, ttl, Keyword.get(opts, :stale_ms, @stale_ms))
        end

        %{result: result, fetched_at: DateTime.utc_now(), from_cache?: false, stored?: stored?}
    end
  end

  # The university failed or answered in part: the last good answer beats
  # it. A dead session is never hidden: the app must log in again.
  defp fallback(_result, {:stale, old, fetched_at}), do: {old, true, fetched_at}
  defp fallback(result, _none), do: {result, false, DateTime.utc_now()}

  defp reauth?({:error, :reauth_required}), do: true

  defp reauth?({:ok, _, %{} = meta}) do
    sources = Map.get(meta, :sources, %{})

    "reauth_required" in Map.values(meta) or
      (is_map(sources) and "reauth_required" in Map.values(sources))
  end

  defp reauth?(_), do: false

  defp ttl(ms, _result) when is_integer(ms), do: ms
  defp ttl(fun, result) when is_function(fun, 1), do: fun.(result)

  defp lookup(key) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _, fetched_at}] when expires_at > now ->
        {:fresh, value, fetched_at}

      [{^key, value, _, stale_until, fetched_at}] when stale_until > now ->
        {:stale, value, fetched_at}

      _ ->
        :miss
    end
  end

  # Lookups made inside another one are not recorded in the meta.
  defp nested(fun) do
    depth = Process.get(@depth_key, 0)
    Process.put(@depth_key, depth + 1)

    try do
      fun.()
    after
      Process.put(@depth_key, depth)
    end
  end

  defp record(cached?, fetched_at) do
    Process.put(@meta_key, [
      %{cached: cached?, fetched_at: fetched_at} | Process.get(@meta_key, [])
    ])
  end

  defp enabled?, do: Application.get_env(:nexo, :upstream_cache, true)

  # --- Server -------------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc false
  def sweep do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])

    if bytes() > max_bytes() do
      # Stale fallbacks go first, then everything.
      :ets.select_delete(@table, [{{:_, :_, :"$1", :_, :_}, [{:<, :"$1", now}], [true]}])

      if bytes() > max_bytes() do
        Logger.warning("Cache over #{max_bytes()} bytes: cleared")
        :ets.delete_all_objects(@table)
      end
    end

    :ok
  end

  defp bytes, do: :ets.info(@table, :memory) * :erlang.system_info(:wordsize)
  defp max_bytes, do: Application.get_env(:nexo, :cache_max_bytes, @max_bytes)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now, do: System.monotonic_time(:millisecond)
end
