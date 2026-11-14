defmodule Nexo.Integrations.Connections do
  @moduledoc """
  "Connect with Nexo": a third-party app gets access to a student's shared
  profile and/or schedule, approved by the student inside the Nexo app.

  It follows the OAuth 2.0 Device Authorization Grant (RFC 8628), so the
  student never types SIGMA credentials into someone else's page:

    1. The app calls `POST /oauth/device` and shows the `user_code`
       (`BDFG-KLMN`) or a `nexo://connect?code=…` link.
    2. In Nexo, the student sees which app asks for what, and approves or
       denies (`/me/connections/requests/:code`).
    3. Meanwhile the app polls `POST /oauth/token` with its `device_code`
       and, once approved, receives an access token (1 hour) and a refresh
       token (rotated on every use).

  Scopes: `profile` and `schedule`. Tokens are stored only as hashes. The
  student lists and revokes connected apps from Nexo; suspending a client
  revokes all of its access at the next request.
  """
  alias Nexo.Infra.Db
  alias Nexo.Integrations.{Clients, Tokens}
  alias Nexo.Security.Audit

  @requests "integration_requests"
  @grants "integration_grants"
  @scopes ~w(profile schedule)
  @request_ttl_s 600
  @poll_interval_s 5
  @access_ttl_s 3600

  def poll_interval, do: @poll_interval_s

  # --- 1. The app starts a request ---------------------------------------------

  def start(client_id, scope) do
    with %{} = client <- Clients.active(client_id) || {:error, :invalid_client},
         {:ok, scopes} <- parse_scope(scope) do
      device_code = Tokens.generate("nxd_")
      user_code = Tokens.user_code()
      now = Db.now()

      {:ok, _} =
        Mongo.insert_one(Db.conn(), @requests, %{
          device_hash: Tokens.hash(device_code),
          user_code: user_code,
          client_id: client.client_id,
          scopes: scopes,
          status: "pending",
          created_at: now,
          expires_at: DateTime.add(now, @request_ttl_s, :second)
        })

      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: "nexo://connect",
         verification_uri_complete: "nexo://connect?code=#{user_code}",
         expires_in: @request_ttl_s,
         interval: @poll_interval_s
       }}
    end
  end

  defp parse_scope(scope) when is_binary(scope) do
    scopes = scope |> String.split(~r/[\s,]+/, trim: true) |> Enum.uniq()

    if scopes != [] and Enum.all?(scopes, &(&1 in @scopes)),
      do: {:ok, scopes},
      else: {:error, :invalid_scope}
  end

  defp parse_scope(_), do: {:error, :invalid_scope}

  # --- 2. The student decides in Nexo ------------------------------------------

  @doc "The pending request behind a user code, with the app's name, for the consent screen."
  def preview(user_code) do
    with {:ok, code} <- Tokens.normalize_user_code(user_code),
         %{} = request <- pending(code),
         %{} = client <- Clients.active(request["client_id"]) do
      {:ok, %{user_code: code, client: client, scopes: request["scopes"]}}
    else
      _ -> {:error, :not_found}
    end
  end

  def decide(user_code, student_id, decision, meta \\ %{})
      when decision in [:approve, :deny] do
    with {:ok, code} <- Tokens.normalize_user_code(user_code),
         %{} = request <- pending(code) do
      status = if decision == :approve, do: "approved", else: "denied"

      Mongo.update_one(Db.conn(), @requests, %{_id: request["_id"], status: "pending"}, %{
        "$set" => %{status: status, student_id: student_id, decided_at: Db.now()}
      })

      Audit.log(
        :"integration_request_#{status}",
        Map.merge(meta, %{
          actor_id: student_id,
          target: request["client_id"],
          scopes: request["scopes"]
        })
      )

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending(user_code) do
    Mongo.find_one(Db.conn(), @requests, %{
      user_code: user_code,
      status: "pending",
      expires_at: %{"$gt" => Db.now()}
    })
  end

  # --- 3. The app polls for its tokens -----------------------------------------

  @doc """
  Exchanges a device code for tokens. Errors follow RFC 8628:
  `authorization_pending`, `slow_down`, `access_denied`, `expired_token`,
  `invalid_grant`, `invalid_client`.
  """
  def exchange_device_code(client_id, device_code)
      when is_binary(client_id) and is_binary(device_code) do
    now = Db.now()

    case Mongo.find_one(Db.conn(), @requests, %{device_hash: Tokens.hash(device_code)}) do
      nil ->
        {:error, :invalid_grant}

      %{"client_id" => other} when other != client_id ->
        {:error, :invalid_client}

      request ->
        cond do
          DateTime.compare(request["expires_at"], now) != :gt ->
            {:error, :expired_token}

          too_fast?(request, now) ->
            touch(request, now)
            {:error, :slow_down}

          request["status"] == "pending" ->
            touch(request, now)
            {:error, :authorization_pending}

          request["status"] == "denied" ->
            Mongo.delete_one(Db.conn(), @requests, %{_id: request["_id"]})
            {:error, :access_denied}

          request["status"] == "approved" ->
            # One use: deleting first means a replayed device code finds nothing.
            case Mongo.delete_one(Db.conn(), @requests, %{_id: request["_id"]}) do
              {:ok, %{deleted_count: 1}} ->
                issue(client_id, request["student_id"], request["scopes"])

              _ ->
                {:error, :invalid_grant}
            end
        end
    end
  end

  def exchange_device_code(_, _), do: {:error, :invalid_request}

  defp too_fast?(%{"last_poll_at" => %DateTime{} = last}, now),
    do: DateTime.diff(now, last) < @poll_interval_s

  defp too_fast?(_, _), do: false

  defp touch(request, now) do
    Mongo.update_one(Db.conn(), @requests, %{_id: request["_id"]}, %{
      "$set" => %{last_poll_at: now}
    })
  end

  @doc "Rotates a refresh token: the old one stops working at once."
  def refresh(client_id, refresh_token) when is_binary(client_id) and is_binary(refresh_token) do
    with %{} = grant <-
           Mongo.find_one(Db.conn(), @grants, %{
             refresh_hash: Tokens.hash(refresh_token),
             client_id: client_id,
             revoked_at: nil
           }),
         %{} <- Clients.active(client_id) do
      rotate(grant)
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def refresh(_, _), do: {:error, :invalid_request}

  defp issue(client_id, student_id, scopes) do
    access = Tokens.generate("nxa_")
    refresh = Tokens.generate("nxr_")
    now = Db.now()

    {:ok, %{inserted_id: _}} =
      Mongo.insert_one(Db.conn(), @grants, %{
        client_id: client_id,
        student_id: student_id,
        scopes: scopes,
        access_hash: Tokens.hash(access),
        access_expires_at: DateTime.add(now, @access_ttl_s, :second),
        refresh_hash: Tokens.hash(refresh),
        created_at: now,
        revoked_at: nil
      })

    {:ok, token_response(access, refresh, scopes)}
  end

  defp rotate(grant) do
    access = Tokens.generate("nxa_")
    refresh = Tokens.generate("nxr_")
    now = Db.now()

    # A parallel refresh with the same token loses the race: invalid grant.
    case Mongo.update_one(
           Db.conn(),
           @grants,
           %{_id: grant["_id"], refresh_hash: grant["refresh_hash"], revoked_at: nil},
           %{
             "$set" => %{
               access_hash: Tokens.hash(access),
               access_expires_at: DateTime.add(now, @access_ttl_s, :second),
               refresh_hash: Tokens.hash(refresh),
               refreshed_at: now
             }
           }
         ) do
      {:ok, %{modified_count: 1}} -> {:ok, token_response(access, refresh, grant["scopes"])}
      _ -> {:error, :invalid_grant}
    end
  end

  defp token_response(access, refresh, scopes) do
    %{
      access_token: access,
      token_type: "Bearer",
      expires_in: @access_ttl_s,
      refresh_token: refresh,
      scope: Enum.join(scopes, " ")
    }
  end

  # --- Using and managing access ------------------------------------------------

  @doc "The live grant behind an access token, or `nil`."
  def verify_access(token) when is_binary(token) do
    with %{} = grant <-
           Mongo.find_one(Db.conn(), @grants, %{
             access_hash: Tokens.hash(token),
             revoked_at: nil,
             access_expires_at: %{"$gt" => Db.now()}
           }),
         %{} <- Clients.active(grant["client_id"]) do
      Mongo.update_one(Db.conn(), @grants, %{_id: grant["_id"]}, %{
        "$set" => %{last_used_at: Db.now()}
      })

      grant
    else
      _ -> nil
    end
  end

  def verify_access(_), do: nil

  @doc "Apps the student has connected, newest first."
  def list(student_id) do
    Db.conn()
    |> Mongo.find(@grants, %{student_id: student_id, revoked_at: nil}, sort: %{created_at: -1})
    |> Enum.map(fn grant ->
      client = Clients.get(grant["client_id"]) || %{}

      %{
        id: Db.id_to_string(grant["_id"]),
        client_id: grant["client_id"],
        name: Map.get(client, :name),
        website: Map.get(client, :website),
        scopes: grant["scopes"],
        connected_at: grant["created_at"],
        last_used_at: grant["last_used_at"]
      }
    end)
  end

  def revoke(student_id, grant_id, meta \\ %{}) do
    with {:ok, oid} <- Db.parse_id(grant_id),
         {:ok, %{modified_count: 1}} <-
           Mongo.update_one(
             Db.conn(),
             @grants,
             %{_id: oid, student_id: student_id, revoked_at: nil},
             %{"$set" => %{revoked_at: Db.now()}}
           ) do
      Audit.log(:integration_revoked, Map.merge(meta, %{actor_id: student_id, target: grant_id}))
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Revokes every app the student connected (when they stop sharing)."
  def revoke_all(student_id) do
    Mongo.update_many(Db.conn(), @grants, %{student_id: student_id, revoked_at: nil}, %{
      "$set" => %{revoked_at: Db.now()}
    })

    :ok
  end
end
