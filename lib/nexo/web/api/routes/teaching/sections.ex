defmodule Nexo.Web.Api.Routes.Teaching.Sections do
  use Nexo.Web.Api.Route,
    name: "teaching.sections",
    method: :get,
    path: "/teaching/sections",
    auth: [:teacher],
    tags: ["teaching"],
    description: "The teacher's sections, merged from SIGMA's two lists: one section, one id."

  alias Nexo.Web.Api.UpstreamReply

  @impl true
  def handle(conn, _params) do
    case Nexo.Teaching.Sections.list(conn.assigns.current_subject) do
      {:ok, sections} -> {:ok, sections, %{source: "sigma"}}
      error -> error
    end
    |> UpstreamReply.reply()
  end
end
