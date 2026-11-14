defmodule Nexo.Security.Password do
  @moduledoc """
  Changes the user's university password through SIGMA
  (`Login/ChangePassword`, the same account for students and teachers).

  Neither password is stored or logged: both travel once to SIGMA, base64
  encoded as SIGMA expects, and the app keeps the new one only on the device.
  """
  alias Nexo.Security.Audit
  alias Nexo.Sigma
  alias Nexo.Upstream.Sessions

  @doc "`:ok`, `{:error, :rejected, message}`, `{:error, :reauth_required}` or `{:error, :unavailable}`."
  def change(%{type: type} = subject, current, new) do
    result =
      Sessions.with_session(subject, :sigma, fn token ->
        body = %{
          "claveActual" => Base.encode64(current),
          "claveNueva" => Base.encode64(new),
          "nomSys" => "SIGMA"
        }

        case Sigma.call(token, :post, "/Login/ChangePassword", %{}, body) do
          {:ok, %{success: true}} -> {:ok, :changed, token}
          {:ok, %{message: message}} -> {:ok, {:rejected, message}, token}
          {:error, _} = error -> error
        end
      end)

    case result do
      {:ok, :changed} ->
        Audit.log(:password_changed, %{actor_type: to_string(type), actor_id: actor(subject)})
        :ok

      {:ok, {:rejected, message}} ->
        {:error, :rejected, message}

      {:error, _} = error ->
        error
    end
  end

  defp actor(%{record: %{"code" => code}}), do: code
  defp actor(%{record: %{"sigma_code" => code}}), do: code
  defp actor(%{id: id}), do: to_string(id)
end
