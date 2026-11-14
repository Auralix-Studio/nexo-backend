defmodule Nexo.Upstream.Intranet do
  @moduledoc """
  The university Intranet (PHP, `PHPSESSID` cookie). Answers are positional
  arrays, sometimes preceded by whitespace. An expired session shows up as a
  `302` to `sesion` or as an HTML page; both are `:session_expired`, never
  "no data".

  The concrete module comes from config (`:intranet_client`) so tests can
  replace it.
  """

  @type cookies :: String.t()
  @type error :: :invalid_credentials | :unavailable | :session_expired

  @callback login(user :: String.t(), password :: String.t()) ::
              {:ok, cookies()} | {:error, error()}

  @callback post(cookies(), path :: String.t(), form :: map(), referer :: String.t()) ::
              {:ok, list(), cookies()} | {:error, error()}

  @callback get(cookies(), path :: String.t(), referer :: String.t()) ::
              {:ok, list(), cookies()} | {:error, error()}

  def login(user, password), do: impl().login(user, password)
  def post(cookies, path, form, referer), do: impl().post(cookies, path, form, referer)
  def get(cookies, path, referer), do: impl().get(cookies, path, referer)

  defp impl, do: Application.get_env(:nexo, :intranet_client, Nexo.Upstream.Intranet.Http)
end
