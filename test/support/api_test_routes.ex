defmodule Nexo.Web.Api.TestRoutes.Echo do
  @moduledoc false
  use Nexo.Web.Api.Route,
    name: "test.echo",
    method: :post,
    path: "/test/echo/:slot",
    auth: :public,
    params: [
      slot: [type: :string, format: "^[a-z]{1,8}$"],
      name: [type: :string, required: true, min: 2, max: 20],
      count: [type: :integer, min: 1, max: 5],
      mode: [type: :string, in: ["fast", "slow"]]
    ],
    description: "Test only: returns the validated params."

  @impl true
  def handle(_conn, params), do: {:ok, params}
end

defmodule Nexo.Web.Api.TestRoutes.EchoSearch do
  @moduledoc false
  use Nexo.Web.Api.Route,
    name: "test.echo.search",
    method: :post,
    path: "/test/echo/search",
    auth: :public,
    description: "Test only: a literal segment must win over /test/echo/:slot."

  @impl true
  def handle(_conn, _params), do: {:ok, %{route: "search"}}
end

defmodule Nexo.Web.Api.TestRoutes.Limited do
  @moduledoc false
  use Nexo.Web.Api.Route,
    name: "test.limited",
    method: :get,
    path: "/test/limited",
    auth: :public,
    rate_limit: {2, 60},
    description: "Test only: two requests per minute."

  @impl true
  def handle(_conn, _params), do: {:ok, %{}}
end

defmodule Nexo.Web.Api.TestRoutes.Boom do
  @moduledoc false
  use Nexo.Web.Api.Route,
    name: "test.boom",
    method: :get,
    path: "/test/boom",
    auth: :public,
    description: "Test only: crashes."

  @impl true
  def handle(_conn, _params), do: raise("secret internal detail")
end

defmodule Nexo.Web.Api.TestRoutes.TeachersOnly do
  @moduledoc false
  use Nexo.Web.Api.Route,
    name: "test.teachers_only",
    method: :get,
    path: "/test/teachers-only",
    auth: [:teacher],
    description: "Test only: teachers."

  @impl true
  def handle(_conn, _params), do: {:ok, %{}}
end
