defmodule Nexo.Infra.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter on ETS.

  Each `hit/3` atomically bumps a counter for `{key, window}` with
  `:ets.update_counter/4`, so concurrent requests never lose a count. The
  GenServer owns the table and drops finished windows every minute.

  Keys are chosen by the caller: the API dispatcher limits by client IP
  before authentication and by subject (user) after it, so many students
  behind the university's shared IP do not block each other.
  """
  use GenServer

  @table :nexo_rate_limit
  @sweep_every :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one request for `key`. Returns `:ok` while under `limit` requests
  per `window_s` seconds, or `{:error, retry_after_seconds}` once over it.
  """
  def hit(key, limit, window_s)
      when is_integer(limit) and limit > 0 and is_integer(window_s) and window_s > 0 do
    now = System.system_time(:second)
    window = div(now, window_s)
    window_end = (window + 1) * window_s
    entry = {key, window_s, window}

    count = :ets.update_counter(@table, entry, {2, 1}, {entry, 0, window_end})

    if count > limit, do: {:error, max(window_end - now, 1)}, else: :ok
  end

  @doc "Clears every counter. Meant for tests."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)
end
