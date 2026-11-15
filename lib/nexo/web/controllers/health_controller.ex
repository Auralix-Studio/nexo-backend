defmodule Nexo.Web.HealthController do
  use Nexo.Web, :controller

  alias Nexo.Infra.{Cache, RateLimiter}
  alias Nexo.Web.ClientIp

  # Probes per client IP and minute; the platform's probe needs a few.
  @per_ip_per_minute 120
  # One Mongo ping serves every probe for this long, however many arrive.
  @ping_ttl 2_000

  @doc """
  Sonda de salud para orquestadores y balanceadores. Comprueba que la conexión
  a MongoDB responde: un proceso vivo con la base caída no es "sano".

  Es pública, así que no puede ser una forma barata de saturar el pool de
  Mongo: tiene límite por IP y el resultado del ping se reutiliza 2 s.
  """
  def show(conn, _params) do
    case RateLimiter.hit({:health, ClientIp.get(conn)}, @per_ip_per_minute, 60) do
      :ok ->
        respond(conn, ping())

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{status: "rate_limited"})
    end
  end

  defp ping do
    {:ok, result} =
      Cache.fetch({:health, :mongo_ping}, @ping_ttl, fn ->
        case Mongo.ping(Nexo.Infra.Db.conn()) do
          {:ok, _} -> {:ok, :ok}
          _ -> {:ok, :error}
        end
      end)

    result
  end

  defp respond(conn, :ok), do: json(conn, %{status: "ok", db: "ok"})

  defp respond(conn, :error) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{status: "degraded", db: "error"})
  end
end
