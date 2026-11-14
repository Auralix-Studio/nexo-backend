defmodule Nexo.Campus.Wifi do
  @moduledoc """
  The student's campus Wi-Fi credential, from SIGMA
  `Recursos/ObtenerWifiUsuario`.

  It is a secret: read on every request, never cached or stored, never
  logged (only the presence of the fields is). The response carries the
  global `cache-control: no-store` header. Upstream key names are not
  confirmed by a captured sample, so the known variants are accepted.
  """
  alias Nexo.Upstream.{Normalize, Sessions}

  @user_keys ~w(usuario user usuarioWifi username)
  @password_keys ~w(contrasena contraseña clave password contrasenaWifi)

  @doc "`{:ok, %{user, password}, meta}` or `{:error, :reauth_required | :unavailable}`."
  def get(subject) do
    with {:ok, data} <- Sessions.sigma_fetch(subject, "/Recursos/ObtenerWifiUsuario") do
      {:ok, build(data), %{source: "sigma"}}
    end
  end

  @doc false
  def build([first | _]), do: build(first)

  def build(%{} = data) do
    %{user: pick(data, @user_keys), password: pick(data, @password_keys)}
  end

  def build(_), do: %{user: nil, password: nil}

  defp pick(data, keys), do: Enum.find_value(keys, &Normalize.text(data[&1]))
end
