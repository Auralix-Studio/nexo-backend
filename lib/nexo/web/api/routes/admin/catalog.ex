defmodule Nexo.Web.Api.Routes.Admin.Catalog do
  use Nexo.Web.Api.Route,
    name: "admin.catalog",
    method: :get,
    path: "/admin/catalog",
    auth: :admin,
    flag: false,
    tags: ["admin"],
    description: "Every API route with its rules, generated from the route modules."

  alias Nexo.Infra.Flags
  alias Nexo.Web.Api.Registry

  @impl true
  def handle(_conn, _params) do
    routes =
      Enum.map(Registry.routes(), fn spec ->
        %{
          name: spec.name,
          method: spec.method |> to_string() |> String.upcase(),
          path: spec.path,
          description: spec.description,
          tags: spec.tags,
          auth: spec.auth,
          attest: spec.attest,
          rate_limit: rate_limit(spec.rate_limit),
          enabled: is_nil(spec.flag) or Flags.enabled?(spec.flag),
          params:
            Enum.map(spec.params, fn {name, rules} ->
              %{
                name: name,
                type: rules[:type],
                required: Keyword.get(rules, :required, false)
              }
            end)
        }
      end)

    {:ok, %{count: length(routes), routes: routes}}
  end

  defp rate_limit(nil), do: nil
  defp rate_limit({count, seconds}), do: %{requests: count, seconds: seconds}
end
