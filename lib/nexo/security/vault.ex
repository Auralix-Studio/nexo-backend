defmodule Nexo.Security.Vault do
  @moduledoc """
  Symmetric encryption of the few sensitive values that must persist: the
  university sessions (`Nexo.Upstream.Sessions`) and the data students share
  (`Nexo.Integrations.SharedData`). Passwords are never stored.

  AES-256-GCM with a key derived from `SECRET_KEY_BASE`: rotating that
  secret invalidates what was stored, which is the intended behaviour.
  """

  @aad "nexo.vault.v1"

  @spec encrypt(String.t()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary()) :: {:ok, String.t()} | :error
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decrypt(_), do: :error

  defp key do
    secret = Application.fetch_env!(:nexo, Nexo.Web.Endpoint)[:secret_key_base]
    :crypto.hash(:sha256, "nexo.vault.key|" <> secret)
  end
end
