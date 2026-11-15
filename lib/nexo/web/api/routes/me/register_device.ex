defmodule Nexo.Web.Api.Routes.Me.RegisterDevice do
  use Nexo.Web.Api.Route,
    name: "me.devices.register",
    method: :post,
    path: "/me/devices",
    auth: [:student],
    rate_limit: {30, 3600},
    params: [
      token: [type: :string, required: true, min: 20, max: 4096, format: "^[A-Za-z0-9_:-]+$"],
      platform: [type: :string, required: true, in: ["android", "ios", "web"]]
    ],
    tags: ["notifications"],
    description:
      "Registers the phone's push token (FCM). Grade notifications start on for a new user."

  alias Nexo.Notifications.{Devices, Settings}

  @impl true
  def handle(conn, %{token: token, platform: platform}) do
    subject = conn.assigns.current_subject
    :ok = Devices.register(subject, token, platform)
    :ok = Settings.ensure(subject)
    {:ok, 201, %{registered: true, notifications: Settings.get(subject)}}
  end
end
