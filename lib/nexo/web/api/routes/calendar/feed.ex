defmodule Nexo.Web.Api.Routes.Calendar.Feed do
  use Nexo.Web.Api.Route,
    name: "calendar.feed",
    method: :get,
    path: "/calendar/:feed",
    auth: :public,
    attest: false,
    rate_limit: {60, 3600},
    params: [feed: [type: :string, format: "^[A-Za-z0-9_-]{43}[.]ics$"]],
    tags: ["integrations"],
    description: "The student's schedule as an iCalendar feed, for calendar apps (secret link)."

  import Plug.Conn
  alias Nexo.Integrations.Calendar

  @impl true
  def handle(conn, %{feed: feed}) do
    key = String.replace_suffix(feed, ".ics", "")

    case Calendar.render(key) do
      {:ok, ics} ->
        conn
        |> put_resp_content_type("text/calendar")
        |> put_resp_header("content-disposition", ~s(inline; filename="nexo.ics"))
        |> send_resp(200, ics)
        |> halt()

      :not_found ->
        {:error, :not_found}
    end
  end
end
