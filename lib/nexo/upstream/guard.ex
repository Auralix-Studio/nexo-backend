defmodule Nexo.Upstream.Guard do
  @moduledoc """
  Protection for the university, around every outbound HTTP call.

  All replicas leave through one or two Azure IPs, so the university sees
  Nexo as a single, very busy client. Per host (`:sigma`, `:intranet`,
  `:languages`, `:languages_auth`) and per replica:

    * **rate limit** — at most `:rate_per_second` calls each second (atomic
      ETS counter per one-second window). Over it, the caller waits for the
      next window, up to `:max_wait_ms`, then gives up with `:throttled`;
    * **circuit breaker** — after `:failure_threshold` consecutive failures
      (transport error, timeout, pool timeout or a 5xx) the host is skipped
      for `:open_ms`; calls fail at once with `:circuit_open`. When that
      time is over one probe call goes through: success closes the
      circuit, failure opens it again. Cached answers keep being served
      meanwhile (`Nexo.Infra.Cache`);
    * **timeouts** — each call gets `:call_timeout_ms`, capped to what is
      left of the request's budget (`Nexo.Infra.Deadline`); a spent budget
      fails at once with `:deadline`;
    * **pool** — calls use the `Nexo.Upstream.Finch` pool (`pools/0`) with
      a short `:pool_timeout_ms`, not Req's default pool.

  Every refusal is an `{:error, reason}` the HTTP clients already read as
  `:unavailable`.
  """
  use GenServer
  require Logger

  alias Nexo.Infra.Deadline

  @table :nexo_upstream_guard
  @finch Nexo.Upstream.Finch

  @defaults [
    rate_per_second: 25,
    max_wait_ms: 2_000,
    failure_threshold: 8,
    open_ms: 30_000,
    call_timeout_ms: 10_000,
    pool_timeout_ms: 2_000,
    pool_size: 25
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def finch, do: @finch

  @doc """
  Runs `fun.(req_options)` for `host` when the guard allows it. `fun` makes
  the Req call with the given options (pool and timeouts) and returns Req's
  result, which is returned as is.
  """
  def run(host, fun) when is_atom(host) and is_function(fun, 1) do
    with :ok <- check_deadline(),
         :ok <- check_circuit(host),
         :ok <- acquire(host) do
      result = fun.(req_options())
      record(host, result)
      result
    end
  end

  @doc "Req options for the guarded pool and the per-call timeout."
  def req_options do
    timeout = max(Deadline.cap(config(:call_timeout_ms)), 1)

    [
      finch: [name: @finch, pool_timeout: config(:pool_timeout_ms)],
      receive_timeout: timeout,
      request_timeout: timeout,
      retry: false
    ]
  end

  @doc "Finch pools: one per university host, sized explicitly."
  def pools do
    size = config(:pool_size)
    conn = [conn_opts: [transport_opts: [timeout: 5_000]]]

    hosts = [
      Application.get_env(:nexo, :sigma_base_url, "https://sigma.upla.edu.pe/api"),
      "https://intranet.upla.edu.pe",
      "https://apidiomas.upla.edu.pe",
      "https://services.upla.edu.pe"
    ]

    hosts
    |> Enum.map(&origin/1)
    |> Enum.uniq()
    |> Map.new(&{&1, [size: size, count: 1] ++ conn})
    |> Map.put(:default, [size: 10, count: 1] ++ conn)
  end

  defp origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  @doc "`:closed`, `:open` or `:half_open` (probe allowed)."
  def circuit(host) do
    case :ets.lookup(@table, {:circuit, host}) do
      [{_, _failures, 0}] -> :closed
      [{_, _failures, until}] -> if until > now(), do: :open, else: :half_open
      [] -> :closed
    end
  end

  @doc "Clears every counter and circuit. Meant for tests."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Deadline ---------------------------------------------------------------

  defp check_deadline do
    if Deadline.remaining() == 0, do: {:error, :deadline}, else: :ok
  end

  # --- Circuit breaker -------------------------------------------------------
  #
  # `{{:circuit, host}, consecutive_failures, open_until}`; `open_until` 0
  # means closed.

  defp check_circuit(host) do
    key = {:circuit, host}

    case :ets.lookup(@table, key) do
      [{^key, _failures, 0}] ->
        :ok

      [{^key, failures, until}] ->
        now = now()

        cond do
          until > now ->
            {:error, :circuit_open}

          # Time is up: the first caller to swap the deadline is the probe;
          # the others keep failing fast until the probe answers.
          probe?(key, failures, until, now) ->
            :ok

          true ->
            {:error, :circuit_open}
        end

      [] ->
        :ok
    end
  end

  defp probe?(key, failures, until, now) do
    probe_until = now + config(:call_timeout_ms) + config(:pool_timeout_ms)

    :ets.select_replace(@table, [
      {{key, failures, until}, [], [{{{key}, failures, probe_until}}]}
    ]) == 1
  end

  defp record(host, result) do
    if failure?(result), do: failed(host), else: succeeded(host)
  end

  defp failure?({:error, _}), do: true
  defp failure?({:ok, %{status: status}}) when status >= 500, do: true
  defp failure?(_), do: false

  defp failed(host) do
    key = {:circuit, host}
    failures = :ets.update_counter(@table, key, {2, 1}, {key, 0, 0})

    if failures >= config(:failure_threshold) do
      open_ms = config(:open_ms)
      :ets.update_element(@table, key, {3, now() + open_ms})

      if failures == config(:failure_threshold),
        do: Logger.warning("Upstream #{host}: circuit open for #{open_ms} ms")
    end

    :ok
  end

  defp succeeded(host) do
    key = {:circuit, host}

    case :ets.lookup(@table, key) do
      [{^key, 0, 0}] -> :ok
      [] -> :ok
      _ -> :ets.insert(@table, {key, 0, 0})
    end

    :ok
  end

  # --- Rate limit ------------------------------------------------------------

  defp acquire(host) do
    wait = min(config(:max_wait_ms), Deadline.cap(config(:max_wait_ms)))
    acquire(host, config(:rate_per_second), now() + wait)
  end

  defp acquire(host, rate, give_up_at) do
    now_ms = System.system_time(:millisecond)
    second = div(now_ms, 1000)
    key = {:rate, host, second}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    cond do
      count <= rate ->
        :ok

      now() >= give_up_at ->
        {:error, :throttled}

      true ->
        # Next window, spread a little so the waiters do not all wake at once.
        sleep = (second + 1) * 1000 - now_ms + :rand.uniform(50)
        Process.sleep(min(sleep, max(give_up_at - now(), 1)))
        acquire(host, rate, give_up_at)
    end
  end

  defp config(key) do
    :nexo
    |> Application.get_env(:upstream_guard, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  defp now, do: System.monotonic_time(:millisecond)

  # --- Server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    second = div(System.system_time(:millisecond), 1000)
    :ets.select_delete(@table, [{{{:rate, :_, :"$1"}, :_}, [{:<, :"$1", second - 1}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.seconds(10))
end
