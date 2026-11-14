defmodule Nexo.Legal do
  @moduledoc """
  Single source of truth for Nexo's legal documents: Términos y Condiciones,
  Política de Privacidad and Política de Cookies.

  The texts live in `priv/legal/*.md` (Spanish, the minimal Markdown the app
  also reads) and are compiled in. `GET /legal` publishes the current
  version so the app asks users to accept a new one as soon as it ships,
  without an app update; the HTML pages (`/terminos`, `/privacidad`,
  `/cookies`) render the same texts.

  Bump `@version` and `@updated_at`, and rewrite `@summary`, whenever a
  document changes in a way users must accept again.

  Acceptances by logged-in users are kept in `legal_acceptances`, one
  document per acceptance and never overwritten: it is the evidence that a
  given person accepted a given version (Ley N.º 29733).
  """
  alias Nexo.Infra.Db
  alias Nexo.Security.Audit

  @version 5
  @updated_at ~D[2026-11-14]
  @summary [
    "La app ahora se comunica solo con la API de Nexo (api.nexo.aurx.pro), alojada en Microsoft Azure (Chile Central) con MongoDB Atlas como base de datos; es la API la que inicia sesión en SIGMA, la Intranet y el Centro de Idiomas en tu nombre.",
    "Tu contraseña nunca se guarda en el servidor: se usa una vez para iniciar sesión. Las sesiones de la universidad se guardan cifradas (AES-256-GCM) y se borran al cerrar sesión.",
    "Detallamos qué datos se tratan (identidad, notas, horario, pagos, Wi-Fi, módulo docente) y las funciones opcionales: directorio, apoderados, calendario, «Conectar con Nexo» y avisos de notas.",
    "Explicamos las medidas de seguridad (TLS, límites de peticiones, registro de auditoría, App Check) y el flujo transfronterizo hacia los proveedores en la nube."
  ]

  @documents [
    %{id: "terms", file: "terminos.md", path: "/terminos", title: "Términos y Condiciones"},
    %{id: "privacy", file: "privacidad.md", path: "/privacidad", title: "Política de Privacidad"},
    %{id: "cookies", file: "cookies.md", path: "/cookies", title: "Política de Cookies"}
  ]

  @texts (for %{id: id, file: file} <- @documents, into: %{} do
            path = Path.join([__DIR__, "..", "..", "priv", "legal", file])
            @external_resource path
            {id, File.read!(path)}
          end)

  @collection "legal_acceptances"

  def collection, do: @collection
  def version, do: @version
  def updated_at, do: @updated_at
  def summary, do: @summary

  @doc "Document ids: `\"terms\"`, `\"privacy\"`, `\"cookies\"`."
  def document_ids, do: Enum.map(@documents, & &1.id)

  @doc "Title, public path and Markdown text of one document."
  def document(id) do
    case Enum.find(@documents, &(&1.id == id)) do
      nil -> :error
      doc -> {:ok, doc |> Map.delete(:file) |> Map.put(:text, Map.fetch!(@texts, id))}
    end
  end

  @doc "What `GET /legal` answers; `base_url` is where the HTML pages are served."
  def info(base_url) do
    %{
      version: @version,
      updated_at: Date.to_iso8601(@updated_at),
      summary: @summary,
      documents:
        for %{id: id, path: path, title: title} <- @documents do
          %{id: id, title: title, url: base_url <> path}
        end
    }
  end

  @doc """
  Records that `subject` accepted `version`. Only versions that were ever
  published (1..current) are accepted.
  """
  def accept(%{type: type, id: id}, version, meta \\ %{}) when is_integer(version) do
    if version in 1..@version do
      now = Db.now()

      doc = %{
        subject_type: to_string(type),
        subject_id: id,
        version: version,
        accepted_at: now,
        ip: meta[:ip],
        user_agent: meta[:user_agent]
      }

      {:ok, _} = Mongo.insert_one(Db.conn(), @collection, doc)

      Audit.log(:legal_accepted, %{
        actor_type: to_string(type),
        actor_id: id,
        version: version,
        ip: meta[:ip]
      })

      {:ok, %{version: version, accepted_at: now, current: version == @version}}
    else
      {:error, :unknown_version}
    end
  end

  @doc "Highest version `subject` has accepted, or `0`."
  def accepted_version(%{type: type, id: id}) do
    Db.conn()
    |> Mongo.find(@collection, %{subject_type: to_string(type), subject_id: id},
      sort: %{version: -1},
      limit: 1
    )
    |> Enum.to_list()
    |> case do
      [%{"version" => version}] -> version
      [] -> 0
    end
  end
end
