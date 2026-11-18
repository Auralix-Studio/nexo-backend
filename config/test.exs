import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nexo, Nexo.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "HYbB8fm46ZQulVfRu7ma5cA38RIRbPdDoNKawzJP6IFYA2bJdxDOnimZ/1EIqAVC",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Los tests usan una base separada y un SIGMA simulado: nunca tocan datos
# reales ni los servidores de la universidad.
config :nexo,
  mongodb_uri:
    System.get_env("MONGODB_URI_TEST") ||
      raise("""
      Falta MONGODB_URI_TEST.

      Copia .env.example a .env y completa la cadena de conexión de pruebas
      (debe apuntar a una base distinta de la de desarrollo).
      """),
  # Pool pequeño: menos conexiones ociosas que Atlas pueda cerrar a mitad
  # de la suite.
  mongodb_pool_size: 2,
  sigma_client: Nexo.SigmaMock,
  intranet_client: Nexo.IntranetMock,
  languages_client: Nexo.LanguagesMock,
  fcm_client: Nexo.FcmMock,
  admin_api_key: "test-admin-key",
  authorized_teachers: "PRE-001",
  system_admins: "62017241"

# Attestation is off by default in tests; the App Check tests switch it on
# with their own signing key.
config :nexo, :app_check,
  mode: :off,
  project_number: "123456789",
  app_ids: ["1:123456789:android:nexo"]

config :nexo, :rate_limits,
  ip_per_minute: 100_000,
  subject_per_minute: 100_000,
  public_ip_per_minute: 100_000

# Tests change the mocked sessions between requests: university data is not
# cached unless a test turns it on (see `Nexo.CacheTest`).
config :nexo, :upstream_cache, false

# Background warm-up of per-term averages would race with cache tests.
config :nexo, :warm_term_averages, false
