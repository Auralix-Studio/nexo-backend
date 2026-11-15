defmodule Nexo.FcmMock do
  @moduledoc """
  FCM for the tests: every message is sent to the test process as
  `{:fcm, message}`. Tokens starting with `dead-` answer `:unregistered`,
  `bad-` `:invalid_argument` and `flaky-` `:unavailable`.
  """
  @behaviour Nexo.Notifications.Fcm

  @impl true
  def enabled?, do: true

  @impl true
  def send(%{token: token} = message) do
    # Messages sent from a task still reach the test that started it.
    pid = List.last(Process.get(:"$callers", [])) || self()
    Kernel.send(pid, {:fcm, message})

    case token do
      "dead-" <> _ -> {:error, :unregistered}
      "bad-" <> _ -> {:error, :invalid_argument}
      "flaky-" <> _ -> {:error, :unavailable}
      _ -> :ok
    end
  end
end
