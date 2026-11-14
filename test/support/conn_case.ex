defmodule Nexo.Web.ConnCase do
  @moduledoc """
  Test case for requests through the endpoint, with helpers to log in and
  to wipe collections of the shared test database.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint Nexo.Web.Endpoint

  using do
    quote do
      @endpoint Nexo.Web.Endpoint

      use Nexo.Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Nexo.Web.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: build_conn()}
  end

  @doc """
  Logs in through `POST /auth/login` (mocked upstreams, `"D001"` is the
  teacher) and sets the bearer token.
  """
  def logged_in(conn, user \\ "D001", password \\ "ok") do
    body =
      conn |> post("/auth/login", %{"user" => user, "password" => password}) |> json_response(200)

    bearer(conn, body["data"]["access_token"])
  end

  @doc "A conn carrying `token`, or a fresh access token for `type` and `id`."
  def bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  def bearer(conn, type, id), do: bearer(conn, Nexo.Security.Auth.sign_access_token(type, id))

  @doc "Empties the given collections."
  def wipe(collections) do
    for c <- collections, do: Mongo.delete_many(Nexo.Infra.Db.conn(), c, %{})
    :ok
  end
end
