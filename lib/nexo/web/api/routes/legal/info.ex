defmodule Nexo.Web.Api.Routes.Legal.Info do
  use Nexo.Web.Api.Route,
    name: "legal.info",
    method: :get,
    path: "/legal",
    auth: :public,
    # Public information: stores, browsers and the app before login read it.
    attest: false,
    tags: ["legal"],
    description: "Current version of the legal documents, what changed and where to read them."

  @impl true
  def handle(_conn, _params), do: {:ok, Nexo.Legal.info(Nexo.Web.Endpoint.url())}
end
