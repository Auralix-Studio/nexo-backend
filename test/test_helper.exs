# Los tests corren contra la base `nexo_test` del cluster: se limpia al inicio
# para que cada corrida sea reproducible.
for collection <- ~w(teachers refresh_tokens audit_log feature_flags integration_data
                     calendar_feeds integration_clients integration_requests
                     integration_grants upstream_sessions) do
  Mongo.delete_many(Nexo.Infra.Db.conn(), collection, %{})
end

ExUnit.start()
