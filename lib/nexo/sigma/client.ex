defmodule Nexo.Sigma.Client do
  @moduledoc """
  Cliente HTTP real contra la API de SIGMA.

  Réplica del contrato que ya usa la app Flutter: la clave viaja en base64,
  `nomSys` identifica el sistema y las respuestas vienen envueltas en
  `{success, data, mensaje}`.

  Un `success: false` en el login es señal POSITIVA de credenciales inválidas;
  cualquier fallo de red o respuesta no-JSON se reporta como `:unavailable`
  para no confundir una caída de SIGMA con una contraseña equivocada (misma
  distinción que hace la app). Un 401 en las consultas significa que el token
  de sesión caducó: `:session_expired`.
  """
  @behaviour Nexo.Sigma

  @impl true
  def verify_login(usuario_id, password) do
    body = %{
      "usuarioId" => usuario_id,
      "clave" => Base.encode64(password),
      "nomSys" => "SIGMA"
    }

    case Req.post(req(), url: "/Login/SesionV1", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"success" => true, "data" => data}}}
      when is_map(data) ->
        info = data["info"] || %{}

        {:ok,
         %{
           code: to_string(info["codigo"] || usuario_id),
           first_name: to_string(info["nombres"] || ""),
           last_name: to_string(info["apellidos"] || ""),
           teacher?: truthy?(info["isDocente"]),
           token: data["token"]
         }}

      # SIGMA rechaza las credenciales de varias formas según el caso: 401
      # (contraseña incorrecta) o un cuerpo `success:false` con estado 200/400
      # (usuario inexistente o desactivado). Todas son credenciales inválidas,
      # no una caída del servicio.
      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{body: %{"success" => false}}} ->
        {:error, :invalid_credentials}

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def list_sections(token) do
    with {:ok, rows} <- get(token, "/Teacher/GetAsignaturaDocenteV1") do
      {:ok, Enum.map(rows, &to_section/1)}
    end
  end

  @impl true
  def list_section_students(token, cle_auto) do
    with {:ok, rows} <-
           get(token, "/Teacher/ListarEstudianteComple", codSaltem: cle_auto) do
      {:ok, Enum.map(rows, &to_student/1)}
    end
  end

  @impl true
  def section_grades(token, cle_auto, unit) do
    with {:ok, rows} <-
           get(token, "/Teacher/NotasEstudianteResumenV1",
             tipoCalificacion: unit,
             cleAuto: cle_auto
           ) do
      {:ok, Enum.map(rows, &to_student/1)}
    end
  end

  @impl true
  def fetch(token, path) do
    case Req.get(req(), url: path, auth: {:bearer, token}) do
      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :session_expired}

      # SIGMA answers a dead session with its web page and status 200.
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if body |> String.trim_leading() |> String.starts_with?("<"),
          do: {:error, :session_expired},
          else: {:error, :unavailable}

      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body["data"]}

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def call(token, method, path, query, body) do
    opts = [method: method, url: path, params: Map.to_list(query), auth: {:bearer, token}]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(req(), opts) do
      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :session_expired}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if body |> String.trim_leading() |> String.starts_with?("<"),
          do: {:error, :session_expired},
          else: {:error, :unavailable}

      # SIGMA reports a rejected write as `success: false` (sometimes with 400).
      {:ok, %Req.Response{status: status, body: %{} = body}} when status in [200, 201, 400] ->
        {:ok, %{success: body["success"] != false, data: body["data"], message: body["mensaje"]}}

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def download(token, path, query) do
    opts = [
      method: :get,
      url: path,
      params: Map.to_list(query),
      auth: {:bearer, token},
      decode_body: false
    ]

    case Req.request(req(), opts) do
      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :session_expired}

      {:ok, %Req.Response{status: 200, body: body} = res} when is_binary(body) and body != "" ->
        type = res |> Req.Response.get_header("content-type") |> List.first()

        cond do
          # A dead session is SIGMA's web page; an error is its JSON envelope.
          body |> String.trim_leading() |> String.starts_with?("<") -> {:error, :session_expired}
          type && type =~ "json" -> {:error, :unavailable}
          true -> {:ok, %{body: body, content_type: type, filename: filename(res)}}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  defp filename(res) do
    with [disposition | _] <- Req.Response.get_header(res, "content-disposition"),
         [_, name] <- Regex.run(~r/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, disposition) do
      URI.decode(name)
    else
      _ -> nil
    end
  end

  defp get(token, path, params \\ []) do
    case Req.get(req(), url: path, params: params, auth: {:bearer, token}) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, Enum.filter(data, &is_map/1)}

      {:ok, %Req.Response{status: 200, body: %{"success" => true}}} ->
        {:ok, []}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :session_expired}

      _other ->
        {:error, :unavailable}
    end
  end

  defp to_section(row) do
    %{
      id: str(row["cleAuto"] || row["id"] || row["saltemId"] || row["nrc"]),
      code: str(row["codigo"] || row["asg_Id"]),
      subject: str(row["asignatura"] || row["nombreAsignatura"]),
      section: str(row["seccion"]),
      periodo: str(row["periodo"] || row["descripcionPeriodo"]),
      enrolled: int(row["matriculados"] || row["cantMatriculados"])
    }
  end

  defp to_student(row) do
    %{
      code: str(row["codigo"] || row["est_Id"]),
      first_name: str(row["nombres"]),
      last_name: str(row["apellidos"]),
      attendance: opt(row["asistencia"]),
      grade: opt(row["nota"] || row["promedio"])
    }
  end

  defp str(nil), do: ""
  defp str(v), do: to_string(v)

  defp opt(nil), do: nil
  defp opt(v), do: to_string(v)

  defp int(v) when is_integer(v), do: v
  defp int(v) when is_binary(v), do: with({n, _} <- Integer.parse(v), do: n)
  defp int(_), do: nil

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
