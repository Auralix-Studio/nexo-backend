defmodule Nexo.Security.AppCheck do
  @moduledoc """
  Proof that a request comes from the official Nexo app, through Firebase
  App Check.

  On each device the app obtains a short-lived token from Firebase after the
  platform vouches for it: Play Integrity on Android, App Attest on iOS.
  A copied APK, a script or a tool such as Postman cannot get one, because
  the attestation checks the app's signature and the device. The app sends
  the token in the `x-firebase-appcheck` header; this module verifies it
  locally, with no call to Firebase per request:

    1. Signature: RS256, against Firebase's public keys (JWKS), cached for
       six hours and refreshed when an unknown key id shows up.
    2. Issuer: `https://firebaseappcheck.googleapis.com/<project number>`.
    3. Audience: contains `projects/<project number>`.
    4. Expiry and issue time, with one minute of clock leeway.
    5. Subject: one of the registered Nexo app ids, so another app in the
       same Firebase project cannot reuse its tokens.

  Modes (config `:nexo, :app_check, :mode`):

    * `:enforce` — requests without a valid token are rejected. Default in
      production. Without a configured project number every request is
      rejected (fails closed).
    * `:monitor` — invalid tokens are only logged; for rolling out.
    * `:off` — no check; development and tests.

  Limit: Firebase App Check attests Android, iOS and the web. A Windows
  build cannot obtain a token, so in `:enforce` it is refused like any
  other client.
  """
  require Logger
  alias Nexo.Infra.Cache

  @header "x-firebase-appcheck"
  @default_jwks_url "https://firebaseappcheck.googleapis.com/v1/jwks"
  @jwks_ttl :timer.hours(6)
  @refresh_cooldown :timer.minutes(1)
  @leeway 60
  @max_token_bytes 4_096

  def header, do: @header

  @spec mode() :: :enforce | :monitor | :off
  def mode do
    case config(:mode, :enforce) do
      mode when mode in [:enforce, :monitor, :off] -> mode
      _unknown -> :enforce
    end
  end

  @doc """
  Checks a request's token according to the current mode. Returns `:ok`
  (with the verified claims when there were any) or `{:error, reason}`.
  """
  @spec check(String.t() | nil) :: {:ok, map() | nil} | {:error, atom()}
  def check(token) do
    case mode() do
      :off ->
        {:ok, nil}

      :monitor ->
        case verify(token) do
          {:ok, claims} ->
            {:ok, claims}

          {:error, reason} ->
            Logger.warning("App Check failed in monitor mode: #{reason}")
            {:ok, nil}
        end

      :enforce ->
        verify(token)
    end
  end

  @spec verify(String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def verify(nil), do: {:error, :missing_token}
  def verify(token) when not is_binary(token), do: {:error, :malformed_token}
  def verify(token) when byte_size(token) > @max_token_bytes, do: {:error, :malformed_token}

  def verify(token) do
    with {:ok, project} <- project_number(),
         [header_b64, payload_b64, signature_b64] <- String.split(token, "."),
         {:ok, header} <- decode_json(header_b64),
         {:ok, kid} <- check_header(header),
         {:ok, claims} <- decode_json(payload_b64),
         {:ok, signature} <- decode_b64(signature_b64),
         {:ok, key} <- public_key(kid),
         :ok <- check_signature(header_b64 <> "." <> payload_b64, signature, key),
         :ok <- check_claims(claims, project) do
      {:ok, claims}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :malformed_token}
    end
  end

  defp project_number do
    case config(:project_number) do
      number when is_binary(number) and number != "" -> {:ok, number}
      _ -> {:error, :not_configured}
    end
  end

  defp check_header(%{"alg" => "RS256", "kid" => kid}) when is_binary(kid), do: {:ok, kid}
  defp check_header(_header), do: {:error, :unsupported_algorithm}

  defp check_signature(signing_input, signature, key) do
    if :public_key.verify(signing_input, :sha256, signature, key),
      do: :ok,
      else: {:error, :bad_signature}
  rescue
    _ -> {:error, :bad_signature}
  end

  defp check_claims(claims, project) do
    now = System.system_time(:second)
    aud = List.wrap(claims["aud"])
    app_ids = config(:app_ids, [])

    cond do
      claims["iss"] != "https://firebaseappcheck.googleapis.com/" <> project ->
        {:error, :wrong_issuer}

      ("projects/" <> project) not in aud ->
        {:error, :wrong_audience}

      not (is_integer(claims["exp"]) and claims["exp"] > now) ->
        {:error, :expired}

      not (is_integer(claims["iat"]) and claims["iat"] <= now + @leeway) ->
        {:error, :not_yet_valid}

      app_ids != [] and claims["sub"] not in app_ids ->
        {:error, :unknown_app}

      true ->
        :ok
    end
  end

  # --- Keys -----------------------------------------------------------------

  defp public_key(kid) do
    with {:ok, keys} <- jwks() do
      case find_key(keys, kid) do
        nil -> refresh_and_find(kid)
        key -> {:ok, key}
      end
    end
  end

  # An unknown key id usually means Firebase rotated its keys. Refetch at most
  # once a minute, so a flood of made-up ids cannot hammer Google for us.
  defp refresh_and_find(kid) do
    if Cache.put_new({:app_check, :jwks_refresh}, true, @refresh_cooldown) do
      Cache.delete({:app_check, :jwks})

      with {:ok, keys} <- jwks() do
        case find_key(keys, kid) do
          nil -> {:error, :unknown_key}
          key -> {:ok, key}
        end
      end
    else
      {:error, :unknown_key}
    end
  end

  defp find_key(keys, kid) do
    Enum.find_value(keys, fn
      %{"kid" => ^kid, "kty" => "RSA", "n" => n, "e" => e} ->
        with {:ok, n} <- decode_b64(n), {:ok, e} <- decode_b64(e) do
          {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp jwks do
    case config(:jwks) do
      keys when is_list(keys) -> {:ok, keys}
      _ -> Cache.fetch({:app_check, :jwks}, @jwks_ttl, &fetch_jwks/0)
    end
  end

  defp fetch_jwks do
    url = config(:jwks_url, @default_jwks_url)

    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        {:ok, keys}

      other ->
        Logger.error("Could not fetch App Check keys: #{inspect(other, limit: 5)}")
        {:error, :keys_unavailable}
    end
  end

  # --- Helpers --------------------------------------------------------------

  defp decode_json(segment) do
    with {:ok, raw} <- decode_b64(segment),
         {:ok, %{} = map} <- Jason.decode(raw) do
      {:ok, map}
    else
      _ -> {:error, :malformed_token}
    end
  end

  defp decode_b64(segment) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :malformed_token}
    end
  end

  defp config(key, default \\ nil) do
    :nexo |> Application.get_env(:app_check, []) |> Keyword.get(key, default)
  end
end
