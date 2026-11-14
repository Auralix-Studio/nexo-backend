defmodule Nexo.Web.Api.Routes.Me.EnableCalendar do
  use Nexo.Web.Api.Route,
    name: "me.calendar.enable",
    method: :post,
    path: "/me/calendar",
    auth: [:student],
    rate_limit: {10, 3600},
    tags: ["integrations"],
    description: "Creates or rotates the private calendar link. The link is shown only once."

  alias Nexo.Integrations.{Calendar, SharedData}

  @impl true
  def handle(conn, _params) do
    id = conn.assigns.current_subject.id

    case SharedData.get(id) do
      :none ->
        {:error, 409, :nothing_shared, "Share your schedule first."}

      {:ok, _} ->
        {:ok, key} = Calendar.enable(id, %{ip: conn.assigns.client_ip})
        url = Nexo.Web.Endpoint.url() <> "/calendar/" <> key <> ".ics"
        webcal = String.replace(url, ~r/^https?:/, "webcal:")

        {:ok,
         %{
           url: url,
           webcal_url: webcal,
           google_url:
             "https://calendar.google.com/calendar/r?cid=" <> URI.encode_www_form(webcal)
         }}
    end
  end
end
