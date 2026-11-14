defmodule Nexo.Teaching.Upstream do
  @moduledoc """
  SIGMA calls of the teacher module, made with the teacher's stored SIGMA
  session. Paths and payloads are the official SIGMA web client's
  (`sigma.upla.edu.pe`, `Docente/*` and `Asignatura/*`), the same the app
  used.
  """
  alias Nexo.Security.Audit
  alias Nexo.Sigma
  alias Nexo.Upstream.Sessions

  @doc "`{:ok, data}` of a successful read; `{:error, reason}` otherwise."
  def get(subject, path, query \\ %{}) do
    session(subject, fn get, _post -> get.(path, query) end)
  end

  @doc """
  Several calls in one session: `fun` gets `get.(path, query)` (data of a
  successful read) and `post.(path, query, body)` (SIGMA's envelope).
  """
  def session(subject, fun) do
    Sessions.with_session(subject, :sigma, fn token ->
      get = fn path, query ->
        case Sigma.call(token, :get, path, query, nil) do
          {:ok, %{success: true, data: data}} -> {:ok, data}
          {:ok, %{success: false}} -> {:error, :unavailable}
          error -> error
        end
      end

      post = fn path, query, body -> Sigma.call(token, :post, path, query, body) end

      try do
        case fun.(get, post) do
          {:ok, value} -> {:ok, value, token}
          error -> error
        end
      rescue
        Nexo.Teaching.SessionExpired -> {:error, :session_expired}
      end
    end)
  end

  @doc "List of maps from a SIGMA `data`."
  def maps(data) when is_list(data), do: Enum.filter(data, &is_map/1)
  def maps(_), do: []

  @doc "Audits a teacher action; `detail` usually names the section."
  def audit(subject, action, detail) do
    Audit.log(action, %{actor_type: "teacher", actor_id: subject.id, detail: detail})
  end
end
