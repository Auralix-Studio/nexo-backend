defmodule Nexo.Infra.Deadline do
  @moduledoc """
  A time budget for the whole API request.

  The dispatcher starts it before running a route; every upstream call
  (`Nexo.Upstream.Guard`) shortens its own timeout to what is left and
  fails fast once it is spent, so a request ends before the app gives up
  on it (25 s) instead of piling work on a slow university.

  The deadline lives in the request process. Tasks started from it
  (`Task.async_stream`) find it through `$callers`.
  """

  @key :nexo_deadline

  @doc "Starts a budget of `ms` milliseconds for the current process."
  def start(ms) when is_integer(ms) and ms > 0 do
    Process.put(@key, now() + ms)
    :ok
  end

  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "Milliseconds left, or `:infinity` when no deadline was started."
  def remaining do
    case find() do
      nil -> :infinity
      deadline -> max(deadline - now(), 0)
    end
  end

  @doc "`ms` capped to what is left of the budget."
  def cap(ms) do
    case remaining() do
      :infinity -> ms
      left -> min(ms, left)
    end
  end

  defp find do
    Process.get(@key) || Enum.find_value(Process.get(:"$callers", []), &from_process/1)
  end

  defp from_process(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> with({@key, deadline} <- List.keyfind(dict, @key, 0), do: deadline)
      nil -> nil
    end
  end

  defp from_process(_), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
