defmodule Nexo.Web.LegalController do
  use Nexo.Web, :controller

  @moduledoc """
  Public HTML pages of the legal documents. The Microsoft Store, Play Store
  and App Store require a reachable privacy policy URL.

  The texts come from `Nexo.Legal` (the same ones `GET /legal` versions and
  the app shows), so the pages and the app never drift apart.
  """

  def terms(conn, _params), do: page(conn, "terms")
  def privacy(conn, _params), do: page(conn, "privacy")
  def cookies(conn, _params), do: page(conn, "cookies")

  defp page(conn, id) do
    {:ok, doc} = Nexo.Legal.document(id)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html(doc))
  end

  defp html(%{title: title, text: text}) do
    date = Calendar.strftime(Nexo.Legal.updated_at(), "%d/%m/%Y")

    links =
      Enum.map_join(Nexo.Legal.document_ids(), " · ", fn id ->
        {:ok, doc} = Nexo.Legal.document(id)
        ~s(<a href="#{doc.path}">#{Plug.HTML.html_escape(doc.title)}</a>)
      end)

    """
    <!doctype html>
    <html lang="es">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{Plug.HTML.html_escape(title)} — Nexo</title>
      <style>
        :root { color-scheme: light dark; --line: rgba(128,128,128,.28); }
        * { box-sizing: border-box; }
        body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
               max-width: 780px; margin: 0 auto; padding: 40px 22px 96px;
               line-height: 1.65; font-size: 16px; }
        header { border-bottom: 1px solid var(--line); padding-bottom: 20px; margin-bottom: 8px; }
        h1 { font-size: 1.9rem; letter-spacing: -0.6px; margin: 0 0 6px; }
        h2 { font-size: 1.2rem; margin: 2.4rem 0 .4rem; letter-spacing: -0.3px; }
        p, li { margin: .5rem 0; }
        ul { padding-left: 1.3rem; }
        a { color: inherit; text-decoration: underline; text-underline-offset: 2px; }
        .muted { opacity: .68; font-size: .9rem; }
        .box { border: 1px solid var(--line); border-radius: 14px; padding: 16px 20px;
               margin: 20px 0; }
        footer { margin-top: 3rem; padding-top: 18px; border-top: 1px solid var(--line); }
      </style>
    </head>
    <body>
      <header>
        <h1>#{inline(title)}</h1>
        <p class="muted">Versión #{Nexo.Legal.version()} · Última actualización: #{date}.</p>
      </header>
      <div class="box">
        <strong>Nexo es una aplicación independiente y no oficial.</strong> No está
        afiliada, patrocinada ni respaldada por la Universidad Peruana Los Andes (UPLA).
      </div>
      <main>
    #{body(text)}
      </main>
      <footer class="muted">
        <p>#{links}</p>
        <p>Nexo · Proyecto estudiantil independiente. Contacto:
          <a href="mailto:alessandrovillogas@outlook.es">alessandrovillogas@outlook.es</a></p>
      </footer>
    </body>
    </html>
    """
  end

  # The documents use a minimal Markdown (`#` title, `##` section, `- ` item,
  # `**bold**`, blank line between blocks), the same the app parses. The
  # `#` title is rendered in the header.
  defp body(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "# "))
    |> Enum.map_join("\n", &block/1)
  end

  defp block(chunk) do
    lines =
      chunk |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case lines do
      ["## " <> heading] ->
        "<h2>#{inline(heading)}</h2>"

      ["- " <> _ | _] ->
        items =
          Enum.map_join(lines, "", fn line ->
            "<li>#{line |> String.trim_leading("- ") |> inline()}</li>"
          end)

        "<ul>#{items}</ul>"

      _ ->
        "<p>#{lines |> Enum.join(" ") |> inline()}</p>"
    end
  end

  defp inline(text) do
    text
    |> Plug.HTML.html_escape()
    |> String.split("**")
    |> Enum.with_index()
    |> Enum.map_join(fn
      {part, i} when rem(i, 2) == 1 -> "<strong>#{part}</strong>"
      {part, _} -> part
    end)
  end
end
