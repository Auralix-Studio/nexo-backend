defmodule Nexo.Integrations.Tokens do
  @moduledoc """
  Random secrets for integrations: calendar feed keys, device codes, access
  and refresh tokens. Only their SHA-256 hash is stored, so a leaked database
  cannot be replayed against the API.
  """

  @doc "A new random secret with a readable prefix (`nxa_`, `nxr_`, ...)."
  def generate(prefix \\ "") do
    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "The stored form of a secret."
  def hash(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  # Consonants only: no accidental words, no look-alikes (0/O, 1/I).
  @user_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"

  @doc "A short code a person types into the app, e.g. `BDFG-KLMN`."
  def user_code do
    chars = for _ <- 1..8, do: Enum.at(@user_alphabet, random_index())
    {left, right} = Enum.split(chars, 4)
    "#{left}-#{right}"
  end

  # Cryptographic and unbiased: bytes 240..255 would favour the first letters.
  defp random_index do
    <<byte>> = :crypto.strong_rand_bytes(1)
    if byte < 240, do: rem(byte, 20), else: random_index()
  end

  @doc "Normalizes what a person typed: upper case, dash in the middle."
  def normalize_user_code(code) when is_binary(code) do
    case code |> String.upcase() |> String.replace(~r/[^A-Z]/, "") do
      <<left::binary-4, right::binary-4>> -> {:ok, left <> "-" <> right}
      _ -> :error
    end
  end

  def normalize_user_code(_), do: :error
end
