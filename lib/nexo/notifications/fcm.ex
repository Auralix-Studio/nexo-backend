defmodule Nexo.Notifications.Fcm do
  @moduledoc """
  Firebase Cloud Messaging. The concrete module comes from config
  (`:fcm_client`) so tests can replace it; `Nexo.Notifications.Fcm.Http`
  talks to the HTTP v1 API.

  `send/1` takes an HTTP v1 `message` (with its `token`) and answers `:ok`,
  or `{:error, :unregistered | :invalid_argument}` when the token is dead
  and must be dropped, or another error for transient failures.
  """

  @type error :: :unregistered | :invalid_argument | :unauthorized | :unavailable | :disabled

  @callback enabled?() :: boolean()
  @callback send(message :: map()) :: :ok | {:error, error()}

  def enabled?, do: impl().enabled?()
  def send(message), do: impl().send(message)

  defp impl, do: Application.get_env(:nexo, :fcm_client, Nexo.Notifications.Fcm.Http)
end
