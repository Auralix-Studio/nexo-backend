defmodule Nexo.Sigma.Client do
  @moduledoc """
  Real SIGMA client, with the official web client's contract: the password
  travels base64 encoded, `nomSys` names the system and answers come
  wrapped in `{success, data, mensaje}`.

  At login, only a positive rejection (`401`, or `success: false` below
  `500`) is `:invalid_credentials`; anything else is `:unavailable`, so an
  outage never looks like a wrong password. On reads, a `401`/`403` or
  SIGMA's HTML page means the session died: `:session_expired`.
  """
  @behaviour Nexo.Sigma

  @impl true
  def verify_login(user, password) do
    body = %{"usuarioId" => user, "clave" => Base.encode64(password), "nomSys" => "SIGMA"}

    case Req.post(req(), url: "/Login/SesionV1", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"success" => true, "data" => data}}}
      when is_map(data) ->
        info = data["info"] || %{}

        {:ok,
         %{
           code: to_string(info["codigo"] || user),
           first_name: to_string(info["nombres"] || ""),
           last_name: to_string(info["apellidos"] || ""),
           teacher?: truthy?(info["isDocente"]),
           token: data["token"]
         }}

      # Wrong password (401), or an unknown or disabled user (`success: false`
      # with 200/400).
      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: status, body: %{"success" => false}}} when status < 500 ->
        {:error, :invalid_credentials}

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def fetch(token, path) do
    case Req.get(req(), url: path, auth: {:bearer, token}) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body["data"]}
      other -> failure(other)
    end
  end

  @impl true
  def call(token, method, path, query, body) do
    opts = [method: method, url: path, params: Map.to_list(query), auth: {:bearer, token}]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(req(), opts) do
      # SIGMA reports a rejected write as `success: false` (sometimes with 400).
      {:ok, %Req.Response{status: status, body: %{} = body}} when status in [200, 201, 400] ->
        {:ok, %{success: body["success"] != false, data: body["data"], message: body["mensaje"]}}

      other ->
        failure(other)
    end
  end

  @impl true
  def download(token, path, query) do
    opts = [url: path, params: Map.to_list(query), auth: {:bearer, token}, decode_body: false]

    case Req.get(req(), opts) do
      {:ok, %Req.Response{status: 200, body: body} = res} when is_binary(body) and body != "" ->
        type = res |> Req.Response.get_header("content-type") |> List.first()

        cond do
          html?(body) -> {:error, :session_expired}
          # An error comes as SIGMA's JSON envelope.
          type && type =~ "json" -> {:error, :unavailable}
          true -> {:ok, %{body: body, content_type: type, filename: filename(res)}}
        end

      other ->
        failure(other)
    end
  end

  # A dead session is a 401/403, or SIGMA's web page with status 200.
  defp failure({:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :session_expired}

  defp failure({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body),
    do: if(html?(body), do: {:error, :session_expired}, else: {:error, :unavailable})

  defp failure(_other), do: {:error, :unavailable}

  defp html?(body), do: body |> String.trim_leading() |> String.starts_with?("<")

  defp filename(res) do
    with [disposition | _] <- Req.Response.get_header(res, "content-disposition"),
         [_, name] <- Regex.run(~r/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, disposition) do
      URI.decode(name)
    else
      _ -> nil
    end
  end

  defp truthy?(true), do: true
  defp truthy?(1), do: true
  defp truthy?(v) when is_binary(v), do: String.downcase(v) in ["true", "1", "s"]
  defp truthy?(_), do: false

  defp req do
    Req.new(
      base_url: Application.get_env(:nexo, :sigma_base_url, "https://sigma.upla.edu.pe/api"),
      headers: [{"user-agent", "Nexo-Backend/0.1 (Elixir)"}],
      receive_timeout: 30_000,
      retry: false
    )
  end
end
