defmodule Nexo.Upstream.Languages.Http do
  @moduledoc false
  @behaviour Nexo.Upstream.Languages

  # Every call goes through the guard (rate limit, circuit breaker, pool, timeout).
  alias Nexo.Upstream.Guard

  @login_url "https://services.upla.edu.pe/Login"
  @api "https://apidiomas.upla.edu.pe"

  @impl true
  def login(user, password) do
    case Guard.run(
           :languages_auth,
           &Req.post(@login_url, [json: %{"codigo" => user, "contraseña" => password}] ++ &1)
         ) do
      {:ok, %{status: 200, body: %{"rpta" => "Correcto", "token" => token}}}
      when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status}} when status < 500 ->
        {:error, :invalid_credentials}

      _ ->
        {:error, :unavailable}
    end
  end

  @impl true
  def get(token, path) do
    case Guard.run(:languages, &Req.get(@api <> path, [auth: {:bearer, token}] ++ &1)) do
      {:ok, %{status: 200, body: %{"resultado" => rows}}} when is_list(rows) -> {:ok, rows}
      {:ok, %{status: 200}} -> {:ok, []}
      {:ok, %{status: 401}} -> {:error, :session_expired}
      _ -> {:error, :unavailable}
    end
  end
end
