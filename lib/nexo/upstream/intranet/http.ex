defmodule Nexo.Upstream.Intranet.Http do
  @moduledoc """
  Real Intranet client, replicating the browser flow the app used: open the
  home page for a cookie, post the login form, accept only a `302` to
  `inicio`, then open `inicio` once so the session is fully initialized.
  """
  @behaviour Nexo.Upstream.Intranet

  @base "https://intranet.upla.edu.pe"
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"

  @impl true
  def login(user, password) do
    with {:ok, home} <- request(:get, "", "", nil, nil),
         cookies = merge_cookies("", home),
         {:ok, res} <-
           request(
             :post,
             "login",
             cookies,
             "",
             %{
               "usuario" => user,
               "contrasena" => password,
               "datosUsuario" => "dni,nomape",
               "captcha_modelo" => "",
               "captcha_respuesta" => ""
             }
           ) do
      cookies = merge_cookies(cookies, res)

      cond do
        res.status == 302 and location(res) =~ "inicio" ->
          _ = request(:get, "inicio?filtro=noticias", cookies, "login", nil)
          {:ok, cookies}

        # An outage is not a wrong password.
        res.status >= 500 ->
          {:error, :unavailable}

        true ->
          {:error, :invalid_credentials}
      end
    end
  end

  @impl true
  def post(cookies, path, form, referer), do: json(:post, path, cookies, referer, form)

  @impl true
  def get(cookies, path, referer), do: json(:get, path, cookies, referer, nil)

  defp json(method, path, cookies, referer, form) do
    with {:ok, res} <- request(method, path, cookies, referer, form) do
      cookies = merge_cookies(cookies, res)
      body = res.body |> to_string() |> String.trim()

      cond do
        res.status == 302 and location(res) =~ "sesion" -> {:error, :session_expired}
        String.starts_with?(body, "<") -> {:error, :session_expired}
        res.status >= 400 -> {:error, :unavailable}
        body == "" -> {:ok, [], cookies}
        true -> decode(body, cookies)
      end
    end
  end

  defp decode(body, cookies) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> {:ok, list, cookies}
      {:ok, _other} -> {:ok, [], cookies}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp request(method, path, cookies, referer, form) do
    headers =
      [
        {"user-agent", @user_agent},
        {"accept", if(form, do: "*/*", else: "text/html,application/xhtml+xml,*/*;q=0.8")},
        {"accept-language", "es-PE,es;q=0.9"},
        {"x-requested-with", "XMLHttpRequest"}
      ] ++
        if(cookies != "", do: [{"cookie", cookies}], else: []) ++
        if(referer, do: [{"referer", "#{@base}/#{referer}"}], else: [])

    opts = [
      method: method,
      url: "#{@base}/#{path}",
      headers: headers,
      redirect: false,
      decode_body: false,
      retry: false,
      receive_timeout: 30_000
    ]

    opts = if form, do: Keyword.put(opts, :form, form), else: opts

    case Req.request(opts) do
      {:ok, res} -> {:ok, res}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp location(res), do: res |> Req.Response.get_header("location") |> List.first("")

  # Keeps the cookie jar as a `name=value; name=value` header.
  defp merge_cookies(current, res) do
    jar =
      current
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)

    res
    |> Req.Response.get_header("set-cookie")
    |> Enum.reduce(jar, fn header, acc ->
      [pair | _] = String.split(header, ";", parts: 2)

      case String.split(String.trim(pair), "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
