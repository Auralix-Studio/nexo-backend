defmodule Nexo.Sigma do
  @moduledoc """
  SIGMA, the university's academic system. The password is used once, to
  log in, and never stored; the SIGMA session token is kept encrypted in
  `Nexo.Upstream.Sessions`.

  The concrete module comes from config (`:sigma_client`) so tests can
  replace it.
  """

  @type profile :: %{
          code: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          teacher?: boolean(),
          token: String.t() | nil
        }

  @type error :: :invalid_credentials | :unavailable | :session_expired

  @callback verify_login(user :: String.t(), password :: String.t()) ::
              {:ok, profile()} | {:error, error()}

  @doc """
  Raw `data` of a SIGMA `GET`, for the normalizers. An HTML answer or a
  401/403 means the session died: `:session_expired`.
  """
  @callback fetch(token :: String.t(), path :: String.t()) ::
              {:ok, term()} | {:error, error()}

  @doc """
  Any SIGMA request with query and JSON body, answered as its envelope
  (`success`, `data`, `mensaje`). Used by the teacher module, which writes.
  """
  @callback call(
              token :: String.t(),
              method :: :get | :post,
              path :: String.t(),
              query :: map(),
              body :: map() | nil
            ) ::
              {:ok, %{success: boolean(), data: term(), message: String.t() | nil}}
              | {:error, error()}

  @doc "A SIGMA file download (a report): the bytes with SIGMA's content type and file name."
  @callback download(token :: String.t(), path :: String.t(), query :: map()) ::
              {:ok, %{body: binary(), content_type: String.t() | nil, filename: String.t() | nil}}
              | {:error, error()}

  def verify_login(user, password), do: impl().verify_login(user, password)
  def fetch(token, path), do: impl().fetch(token, path)
  def download(token, path, query \\ %{}), do: impl().download(token, path, query)

  def call(token, method, path, query \\ %{}, body \\ nil),
    do: impl().call(token, method, path, query, body)

  defp impl, do: Application.get_env(:nexo, :sigma_client, Nexo.Sigma.Client)
end
