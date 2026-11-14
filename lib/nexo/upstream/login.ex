defmodule Nexo.Upstream.Login do
  @moduledoc """
  One login for the whole app.

  The password is checked against SIGMA (the role — student or teacher —
  comes from there), then the Intranet and Language Center sessions are
  opened in parallel for students. All university sessions are stored
  encrypted (`Nexo.Upstream.Sessions`); **the password is not stored**.

  If SIGMA is down, a student can still log in through the Intranet, which
  also checks the password. Only a positive rejection is reported as invalid
  credentials; an outage is reported as such.
  """
  alias Nexo.People.{Students, Teachers}
  alias Nexo.Security.{Audit, Auth}
  alias Nexo.Sigma
  alias Nexo.Infra.Db
  alias Nexo.Upstream.{Intranet, Languages, Normalize, Sessions}

  @parallel_timeout 30_000

  @doc "`{:ok, session}` or `{:error, :invalid_credentials | :unavailable}`."
  def login(user, password, meta \\ %{}) when is_binary(user) and is_binary(password) do
    user = String.trim(user)

    case Sigma.verify_login(user, password) do
      {:ok, %{teacher?: true} = profile} -> teacher(profile, meta)
      {:ok, profile} -> student(profile, user, password, %{sigma: profile.token}, meta)
      {:error, :invalid_credentials} -> {:error, :invalid_credentials}
      {:error, _} -> intranet_only(user, password, meta)
    end
  end

  defp teacher(profile, meta) do
    {:ok, teacher} = Teachers.upsert_teacher_from_sigma(profile)
    id = Db.id_to_string(teacher["_id"])
    subject = %{type: :teacher, id: id}
    :ok = Sessions.put(subject, %{sigma: profile.token})
    audit(:teacher, teacher["sigma_code"], meta)

    {:ok,
     session(subject, %{
       code: teacher["sigma_code"],
       role: "teacher",
       first: teacher["first_name"],
       last: teacher["last_name"],
       sources: %{sigma: "ok", intranet: "not_applicable", languages: "not_applicable"}
     })}
  end

  defp student(profile, user, password, sessions, meta) do
    [intranet, languages] =
      [fn -> Intranet.login(user, password) end, fn -> Languages.login(user, password) end]
      |> Task.async_stream(& &1.(), timeout: @parallel_timeout, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> {:error, :unavailable}
      end)

    {:ok, student} = Students.upsert_from_sigma(profile)
    id = Db.id_to_string(student["_id"])
    subject = %{type: :student, id: id}

    # A student without a Language Center account is remembered as such, so
    # their requests do not try (and fail) to log in there every time.
    languages_session =
      case languages do
        {:ok, token} -> token
        {:error, :invalid_credentials} -> Nexo.Academic.Languages.no_access_marker()
        _ -> nil
      end

    sessions =
      sessions
      |> Map.put(:intranet, ok(intranet))
      |> Map.put(:languages, languages_session)

    :ok = Sessions.put(subject, sessions)
    audit(:student, student["code"], meta)

    {:ok,
     session(subject, %{
       code: student["code"],
       role: "student",
       first: student["first_name"],
       last: student["last_name"],
       sources: %{
         sigma: if(sessions[:sigma], do: "ok", else: "unavailable"),
         intranet: status(intranet),
         languages: status(languages)
       }
     })}
  end

  # SIGMA is down: the Intranet confirms the password instead. Only students
  # have Intranet access, so the account is treated as a student.
  defp intranet_only(user, password, meta) do
    case Intranet.login(user, password) do
      {:ok, _cookies} ->
        existing = Students.get_by_code(user) || %{}

        profile = %{
          code: user,
          first_name: existing["first_name"] || "",
          last_name: existing["last_name"] || ""
        }

        with {:ok, session} <- student(profile, user, password, %{}, meta) do
          {:ok, put_in(session, [:sources, :sigma], "unavailable")}
        end

      {:error, :invalid_credentials} ->
        {:error, :invalid_credentials}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp session(%{type: type, id: id}, user) do
    first = Normalize.text(user.first)
    last = Normalize.text(user.last)

    %{
      access_token: Auth.sign_access_token(type, id),
      refresh_token: Auth.issue_refresh_token(type, id),
      expires_in: Auth.access_ttl_seconds(),
      user: %{
        code: user.code,
        role: user.role,
        name: %{
          first: first,
          last: last,
          full: [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> Normalize.text()
        },
        photo_url: Normalize.photo_url(user.code)
      },
      sources: user.sources
    }
  end

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil

  defp status({:ok, _}), do: "ok"
  defp status({:error, :invalid_credentials}), do: "no_access"
  defp status(_), do: "unavailable"

  defp audit(type, code, meta) do
    Audit.log(:login, Map.merge(meta, %{actor_type: to_string(type), actor_id: code}))
  end
end
