defmodule Nexo.Notifications.Fcm.Http do
  @moduledoc """
  FCM HTTP v1 with a service account.

  The service account JSON comes from config (`:fcm_service_account_json`,
  filled from `FCM_SERVICE_ACCOUNT_JSON` or `FCM_SERVICE_ACCOUNT_FILE` in
  `runtime.exs`); without it pushes are disabled. A JWT signed with the
  account's RS256 key is exchanged for an OAuth access token, cached for
  55 minutes. Neither the key nor the tokens are ever logged.
  """
  @behaviour Nexo.Notifications.Fcm

  alias Nexo.Infra.Cache

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @token_ttl :timer.minutes(55)
  @token_key {:fcm, :access_token}

  @impl true
  def enabled?, do: match?({:ok, _}, account())

  @impl true
  def send(message) when is_map(message) do
    with {:ok, account} <- account(),
         {:ok, access_token} <- access_token(account) do
      url = "https://fcm.googleapis.com/v1/projects/#{account["project_id"]}/messages:send"

      case Req.post(url,
             json: %{message: message},
             auth: {:bearer, access_token},
             retry: false,
             receive_timeout: 10_000
           ) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        {:ok, %Req.Response{status: 401}} ->
          Cache.delete(@token_key)
          {:error, :unauthorized}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, _} ->
          {:error, :unavailable}
      end
    end
  end

  @doc false
  def classify(status, body) do
    error = if is_map(body), do: body["error"] || %{}, else: %{}

    codes =
      for detail <- List.wrap(error["details"]),
          is_map(detail),
          code = detail["errorCode"],
          do: code

    cond do
      "UNREGISTERED" in codes or status == 404 -> :unregistered
      "INVALID_ARGUMENT" in codes or error["status"] == "INVALID_ARGUMENT" -> :invalid_argument
      true -> :unavailable
    end
  end

  @doc "The parsed service account, or `{:error, :disabled}`."
  def account do
    with json when is_binary(json) and json != "" <-
           Application.get_env(:nexo, :fcm_service_account_json),
         {:ok, %{"client_email" => email, "private_key" => key, "project_id" => project} = acc}
         when is_binary(email) and is_binary(key) and is_binary(project) <- Jason.decode(json) do
      {:ok, acc}
    else
      _ -> {:error, :disabled}
    end
  end

  defp access_token(account) do
    Cache.fetch(@token_key, @token_ttl, fn ->
      token_uri = account["token_uri"] || @default_token_uri

      form = [
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: assertion(account, System.os_time(:second))
      ]

      case Req.post(token_uri, form: form, retry: false, receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}}
        when is_binary(token) ->
          {:ok, token}

        {:ok, %Req.Response{status: status}} when status in [400, 401, 403] ->
          {:error, :unauthorized}

        _ ->
          {:error, :unavailable}
      end
    end)
  end

  @doc "The signed JWT exchanged for an access token (RFC 7523)."
  def assertion(account, now) do
    header = encode(%{alg: "RS256", typ: "JWT"})

    claims =
      encode(%{
        iss: account["client_email"],
        scope: @scope,
        aud: account["token_uri"] || @default_token_uri,
        iat: now,
        exp: now + 3600
      })

    input = header <> "." <> claims
    [entry | _] = :public_key.pem_decode(account["private_key"])
    key = :public_key.pem_entry_decode(entry)
    input <> "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
