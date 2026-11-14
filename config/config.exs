# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Carga un `.env` local (no versionado) para desarrollo y tests. Ningún secreto
# vive en este repositorio: en producción las variables llegan del entorno del
# contenedor. Ver `.env.example`.
if File.exists?(".env") do
  ".env"
  |> File.read!()
  |> String.split(["\n", "\r\n"], trim: true)
  |> Enum.reject(&(String.starts_with?(String.trim(&1), "#") or String.trim(&1) == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(String.trim(key), String.trim(value))
      _ -> :ok
    end
  end)
end

config :nexo,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :nexo, Nexo.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Nexo.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Nexo.PubSub,
  live_view: [signing_salt: "WvrRrwF6"]

# Proof that requests come from the official app (see `Nexo.Security.AppCheck`).
# Production overrides these from the environment in `runtime.exs`.
config :nexo, :app_check,
  mode: :enforce,
  project_number: nil,
  app_ids: [],
  jwks_url: "https://firebaseappcheck.googleapis.com/v1/jwks"

config :nexo, :rate_limits,
  ip_per_minute: 300,
  subject_per_minute: 120

# Peers allowed to report the client IP (the Cloudflare tunnel runs on the
# same host).
config :nexo, :trusted_proxies, ["127.0.0.1", "::1"]

# Where the student directory comes from (see `Nexo.Academic.Directory.Source`).
# Sample students until the university's endpoint exists.
config :nexo, :directory_source, Nexo.Academic.Directory.SampleSource

# Hosts the API answers; empty means any (see `Nexo.Web.HostGuard`).
config :nexo, :allowed_hosts, []

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :api_route]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
