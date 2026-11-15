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

  @version 6
  @updated_at ~D[2026-11-15]
  @summary [
    "Los avisos de notas ya están disponibles: cuando un docente registra tu nota en Nexo, recibes una notificación con el curso, la evaluación y la nota. Son opcionales (Ajustes → «Notificaciones de notas»).",
    "El servidor no revisa tus notas periódicamente ni inicia sesión por ti para buscarlas; guarda solo el identificador de notificaciones de tu dispositivo hasta que cierres sesión.",
    "Firebase Cloud Messaging (Google) se suma como encargado para entregar los avisos.",
    "Tu información se mantiene temporalmente en la memoria del servidor (como máximo un día) para responder más rápido y no sobrecargar a la UPLA; se borra al cerrar sesión."
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
