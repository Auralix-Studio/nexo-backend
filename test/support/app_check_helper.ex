defmodule Nexo.Web.AppCheckHelper do
  @moduledoc "Signs App Check tokens with a test key and points `Nexo.Security.AppCheck` at it."

  @kid "test-key"
  @project "123456789"
  @app_id "1:123456789:android:nexo"

  def project, do: @project
  def app_id, do: @app_id

  @doc "Switches App Check to `mode` with a fresh key; restores config on exit."
  def enable(mode \\ :enforce) do
    previous = Application.get_env(:nexo, :app_check)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

    jwk = %{
      "kid" => @kid,
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e))
    }

    Application.put_env(
      :nexo,
      :app_check,
      Keyword.merge(previous, mode: mode, jwks: [jwk])
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:nexo, :app_check, previous) end)
    key
  end

  def token(key, overrides \\ %{}, header_overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://firebaseappcheck.googleapis.com/#{@project}",
          "aud" => ["projects/#{@project}", "projects/nexo-test"],
          "sub" => @app_id,
          "iat" => now,
          "exp" => now + 3600
        },
        overrides
      )

    header = Map.merge(%{"alg" => "RS256", "typ" => "JWT", "kid" => @kid}, header_overrides)
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    input <> "." <> b64(:public_key.sign(input, :sha256, key))
  end

  defp b64(raw), do: Base.url_encode64(raw, padding: false)
end
