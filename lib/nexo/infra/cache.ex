defmodule Nexo.Infra.Cache do
  @moduledoc """
  In-memory cache with per-entry TTL, backed by a public ETS table.

  Reads and writes go straight to ETS from the caller's process; the
  GenServer only owns the table and sweeps expired entries once a minute.
  Expiry uses monotonic time, so a wall-clock change cannot resurrect or
  kill entries early.
  """
  use GenServer

  @table :nexo_cache
  @sweep_every :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, value}` for a live entry, `:miss` otherwise."
  def get(key) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  @doc "Stores `value` under `key` for `ttl_ms` milliseconds."
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    :ets.insert(@table, {key, value, now() + ttl_ms})
    :ok
  end

  @doc "Stores only when no live entry exists. Returns `true` if it stored."
  def put_new(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    case get(key) do
      {:ok, _} -> false
      :miss -> :ets.insert(@table, {key, value, now() + ttl_ms})
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
  """
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fun.() do
          {:ok, value} ->
            put(key, value, ttl_ms)
            {:ok, value}

          other ->
            other
        end
    end
  end

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
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now, do: System.monotonic_time(:millisecond)
end
