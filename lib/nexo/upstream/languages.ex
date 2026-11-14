defmodule Nexo.Upstream.Languages do
  @moduledoc """
  The university Language Center (Idiomas). Login lives on
  `services.upla.edu.pe`, data on `apidiomas.upla.edu.pe`; the login body
  uses the key `contraseña` and the plain password, and success is the
  string `"Correcto"`.
  """

  @type error :: :invalid_credentials | :unavailable | :session_expired

  @callback login(user :: String.t(), password :: String.t()) ::
              {:ok, token :: String.t()} | {:error, error()}

  @callback get(token :: String.t(), path :: String.t()) ::
              {:ok, list()} | {:error, error()}

  def login(user, password), do: impl().login(user, password)
  def get(token, path), do: impl().get(token, path)

  defp impl, do: Application.get_env(:nexo, :languages_client, Nexo.Upstream.Languages.Http)
end
