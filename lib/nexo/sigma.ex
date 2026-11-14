defmodule Nexo.Sigma do
  @moduledoc """
  Acceso a SIGMA (UPLA).

  El backend NUNCA persiste la contraseña: se usa una sola vez para confirmar
  que quien se registra es un docente real y se descarta. De ese login se
  conserva el *token* de sesión de SIGMA — cifrado (ver `Nexo.Security.Vault`) — que es
  lo que permite consultar secciones y notas en nombre del docente. Cuando ese
  token caduca, el docente vuelve a iniciar sesión.

  El módulo concreto se resuelve por configuración para sustituirlo en tests.
  """

  @type profile :: %{
          code: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          teacher?: boolean(),
          token: String.t() | nil
        }

  @type section :: %{
          id: String.t(),
          code: String.t(),
          subject: String.t(),
          section: String.t(),
          periodo: String.t(),
          enrolled: integer() | nil
        }

  @type student :: %{
          code: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          attendance: String.t() | nil,
          grade: String.t() | nil
        }

  @type error :: :invalid_credentials | :unavailable | :session_expired

  @callback verify_login(usuario_id :: String.t(), password :: String.t()) ::
              {:ok, profile()} | {:error, error()}

  @callback list_sections(token :: String.t()) :: {:ok, [section()]} | {:error, error()}

  @callback list_section_students(token :: String.t(), cle_auto :: String.t()) ::
              {:ok, [student()]} | {:error, error()}

  @callback section_grades(token :: String.t(), cle_auto :: String.t(), unit :: String.t()) ::
              {:ok, [student()]} | {:error, error()}

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

  @doc """
  A SIGMA file download (a report): the raw bytes with the content type and
  file name SIGMA sent, if any.
  """
  @callback download(token :: String.t(), path :: String.t(), query :: map()) ::
              {:ok, %{body: binary(), content_type: String.t() | nil, filename: String.t() | nil}}
              | {:error, error()}

  def verify_login(usuario_id, password), do: impl().verify_login(usuario_id, password)
  def download(token, path, query \\ %{}), do: impl().download(token, path, query)
  def fetch(token, path), do: impl().fetch(token, path)

  def call(token, method, path, query \\ %{}, body \\ nil),
    do: impl().call(token, method, path, query, body)

  def list_sections(token), do: impl().list_sections(token)
  def list_section_students(token, cle_auto), do: impl().list_section_students(token, cle_auto)
  def section_grades(token, cle_auto, unit), do: impl().section_grades(token, cle_auto, unit)

  defp impl do
    Application.get_env(:nexo, :sigma_client, Nexo.Sigma.Client)
  end
end
