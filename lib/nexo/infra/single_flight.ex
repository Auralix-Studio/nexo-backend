defmodule Nexo.Infra.SingleFlight do
  @moduledoc """
  One computation per key in flight; concurrent callers of the same key wait
  for it and get its result instead of repeating the work (no stampede).

  The first caller of a key computes in its own process. Callers that
  arrive meanwhile wait (`GenServer.call`) and receive the same result. If
  the computing process dies, the first waiter is promoted and computes;
  a waiter that gives up (timeout) computes on its own.

  Only bookkeeping goes through the GenServer; the work never runs in it.
  """
  use GenServer

  @wait_ms 25_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun` once for `key` across concurrent callers.

  Returns `{:computed, result}` to the caller that ran `fun`, and
  `{:shared, result}` to the callers that waited for it.
  """
  def run(key, fun, wait_ms \\ @wait_ms) when is_function(fun, 0) do
    case join(key, wait_ms) do
      :run -> {:computed, compute(key, fun)}
      {:shared, result} -> {:shared, result}
      :alone -> {:computed, fun.()}
    end
  end

  defp join(key, wait_ms) do
    GenServer.call(__MODULE__, {:join, key}, wait_ms)
  catch
    # Waited too long, or the server is gone: do the work without it.
    :exit, _ -> :alone
  end

  defp compute(key, fun) do
    result =
      try do
        fun.()
      catch
        kind, reason ->
          GenServer.cast(__MODULE__, {:abort, key, self()})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    GenServer.cast(__MODULE__, {:done, key, self(), result})
    result
  end

  # --- Server ---------------------------------------------------------------
  #
  # State: %{key => %{owner: pid, ref: monitor_ref, waiters: :queue}} plus
  # %{ref => key} to find the key of a dead owner.

  @impl true
  def init(_opts), do: {:ok, %{flights: %{}, refs: %{}}}

  @impl true
  def handle_call({:join, key}, {pid, _} = from, state) do
    case state.flights do
      %{^key => flight} ->
        flights =
          Map.put(state.flights, key, %{flight | waiters: :queue.in(from, flight.waiters)})

        {:noreply, %{state | flights: flights}}

      _ ->
        {:reply, :run, start_flight(state, key, pid, :queue.new())}
    end
  end

  @impl true
  def handle_cast({:done, key, pid, result}, state) do
    case state.flights do
      %{^key => %{owner: ^pid} = flight} ->
        for waiter <- :queue.to_list(flight.waiters),
            do: GenServer.reply(waiter, {:shared, result})

        {:noreply, finish(state, key, flight)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:abort, key, pid}, state) do
    case state.flights do
      %{^key => %{owner: ^pid} = flight} ->
        {:noreply, promote(finish(state, key, flight), key, flight)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    with {:ok, key} <- Map.fetch(state.refs, ref),
         %{owner: ^pid} = flight <- state.flights[key] do
      {:noreply, promote(finish(state, key, flight), key, flight)}
    else
      _ -> {:noreply, state}
    end
  end

  defp start_flight(state, key, pid, waiters) do
    ref = Process.monitor(pid)

    %{
      state
      | flights: Map.put(state.flights, key, %{owner: pid, ref: ref, waiters: waiters}),
        refs: Map.put(state.refs, ref, key)
    }
  end

  defp finish(state, key, flight) do
    Process.demonitor(flight.ref, [:flush])
    %{state | flights: Map.delete(state.flights, key), refs: Map.delete(state.refs, flight.ref)}
  end

  # The owner failed: the next waiter computes, the rest keep waiting for it.
  defp promote(state, key, flight) do
    case :queue.out(flight.waiters) do
      {{:value, {pid, _} = next}, rest} ->
        GenServer.reply(next, :run)
        start_flight(state, key, pid, rest)

      {:empty, _} ->
        state
    end
  end
end
