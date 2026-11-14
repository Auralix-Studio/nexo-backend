defmodule Nexo.Web.Api.Route do
  @moduledoc """
  One module per endpoint, discovered automatically by `Nexo.Web.Api.Registry`.

      defmodule Nexo.Web.Api.Routes.Students.Show do
        use Nexo.Web.Api.Route,
          name: "students.show",
          method: :get,
          path: "/students/:code",
          auth: [:teacher],
          params: [code: [type: :string, format: "^[A-Z0-9]{6,10}$"]],
          rate_limit: {60, 60},
          description: "One student's record."

        @impl true
        def handle(conn, %{code: code}), do: {:ok, %{code: code}}
      end

  Options:

    * `:name` — unique id; also the route's feature flag name.
    * `:method` — `:get | :post | :put | :patch | :delete`.
    * `:path` — from the root of the API host (no version prefix); `:segment` marks a path parameter.
    * `:auth` — `:public`, `:admin` (`x-admin-key`) or a list of subject
      types allowed to call it (`:teacher`, `:student`, `:guardian`).
    * `:params` — whitelist of accepted params with their rules (see
      `Nexo.Web.Api.Params`). Anything not listed never reaches `handle/2`.
      Path parameters are added as required strings unless declared.
    * `:attest` — require proof that the call comes from the Nexo app
      (default `true`; see `Nexo.Security.AppCheck`).
    * `:rate_limit` — extra `{requests, seconds}` limit for this route, on
      top of the global ones.
    * `:flag` — `false` exempts the route from feature flags (admin routes,
      so the switch cannot lock itself out).
    * `:description`, `:tags` — shown in the admin catalog.

  The spec is validated while compiling: a typo in a route fails the build
  instead of silently dropping the endpoint.

  `handle/2` returns `{:ok, data}`, `{:ok, status, data}`, `{:error, code}`
  or `{:error, status, code, message}`; the dispatcher wraps it in the
  standard response envelope. Returning a `Plug.Conn` sends it as is.
  """

  @type result ::
          {:ok, term()}
          | {:ok, pos_integer(), term()}
          | {:error, atom()}
          | {:error, pos_integer(), atom() | String.t(), String.t()}
          | Plug.Conn.t()

  @callback handle(Plug.Conn.t(), map()) :: result()

  @methods [:get, :post, :put, :patch, :delete]
  @subjects [:teacher, :student, :guardian]
  @param_types [:string, :integer, :boolean, :map, :list]
  @integration_scopes ~w(profile schedule)
  @param_keys [:type, :required, :min, :max, :format, :in]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Nexo.Web.Api.Route
      @nexo_api_spec Nexo.Web.Api.Route.build_spec!(__MODULE__, opts)

      @doc false
      def __route__, do: @nexo_api_spec
    end
  end

  @doc false
  def build_spec!(module, opts) do
    name = fetch!(opts, :name, module)
    method = fetch!(opts, :method, module)
    path = fetch!(opts, :path, module)

    unless is_binary(name) and name =~ ~r/^[a-z0-9_.-]{1,64}$/,
      do: fail!(module, "name must match ^[a-z0-9_.-]{1,64}$")

    unless method in @methods, do: fail!(module, "method must be one of #{inspect(@methods)}")

    unless is_binary(path) and String.starts_with?(path, "/"),
      do: fail!(module, "path must start with /")

    segments = parse_path!(module, path)
    auth = validate_auth!(module, Keyword.get(opts, :auth, :public))
    params = validate_params!(module, Keyword.get(opts, :params, []), segments)

    %Nexo.Web.Api.Spec{
      module: module,
      name: name,
      method: method,
      path: path,
      segments: segments,
      description: Keyword.get(opts, :description, ""),
      auth: auth,
      params: params,
      attest: validate_attest!(module, auth, Keyword.get(opts, :attest, auth != :integration)),
      rate_limit: validate_rate_limit!(module, Keyword.get(opts, :rate_limit)),
      flag: validate_flag!(module, Keyword.get(opts, :flag, name)),
      tags: Keyword.get(opts, :tags, []),
      scopes: validate_scopes!(module, auth, Keyword.get(opts, :scopes, []))
    }
  end

  defp fetch!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> fail!(module, "missing required option #{inspect(key)}")
    end
  end

  defp parse_path!(module, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> param ->
        unless param =~ ~r/^[a-z][a-z0-9_]*$/,
          do: fail!(module, "invalid path parameter #{inspect(param)}")

        {:param, String.to_atom(param)}

      literal ->
        unless literal =~ ~r/^[a-z0-9_.-]+$/,
          do: fail!(module, "invalid path segment #{inspect(literal)}")

        {:literal, literal}
    end)
  end

  defp validate_auth!(_module, auth) when auth in [:public, :admin, :integration], do: auth

  defp validate_auth!(module, auth) when is_list(auth) and auth != [] do
    if Enum.all?(auth, &(&1 in @subjects)),
      do: auth,
      else: fail!(module, "auth subjects must be within #{inspect(@subjects)}")
  end

  defp validate_auth!(module, _),
    do: fail!(module, "auth must be :public, :admin or a list of subjects")

  defp validate_params!(module, params, segments) do
    unless Keyword.keyword?(params), do: fail!(module, "params must be a keyword list")

    declared =
      Enum.map(params, fn {name, rules} ->
        unless Keyword.keyword?(rules),
          do: fail!(module, "rules for #{name} must be a keyword list")

        unknown = Keyword.keys(rules) -- @param_keys
        if unknown != [], do: fail!(module, "unknown rules #{inspect(unknown)} for #{name}")

        type = Keyword.get(rules, :type, :string)

        unless type in @param_types,
          do: fail!(module, "type of #{name} must be in #{inspect(@param_types)}")

        case Keyword.get(rules, :format) do
          nil ->
            :ok

          format when is_binary(format) ->
            case Regex.compile(format) do
              {:ok, _} -> :ok
              {:error, _} -> fail!(module, "invalid format for #{name}")
            end

          _ ->
            fail!(module, "format for #{name} must be a regex source string")
        end

        {name, Keyword.put(rules, :type, type)}
      end)

    path_params =
      for {:param, name} <- segments,
          not Keyword.has_key?(declared, name),
          do: {name, [type: :string, required: true]}

    declared ++ path_params
  end

  # Integration routes are called by third-party apps with a scoped token, so
  # they must declare the scopes they need and cannot require app attestation.
  defp validate_scopes!(module, :integration, scopes) do
    unless is_list(scopes) and scopes != [] and Enum.all?(scopes, &(&1 in @integration_scopes)),
      do: fail!(module, "integration routes need scopes within #{inspect(@integration_scopes)}")

    scopes
  end

  defp validate_scopes!(_module, _auth, []), do: []

  defp validate_scopes!(module, _auth, _),
    do: fail!(module, "only integration routes take scopes")

  defp validate_attest!(module, :integration, true),
    do: fail!(module, "integration routes cannot require app attestation")

  defp validate_attest!(module, _auth, value), do: validate_boolean!(module, :attest, value)

  defp validate_boolean!(_module, _key, value) when is_boolean(value), do: value
  defp validate_boolean!(module, key, _), do: fail!(module, "#{key} must be a boolean")

  defp validate_rate_limit!(_module, nil), do: nil

  defp validate_rate_limit!(_module, {count, seconds} = limit)
       when is_integer(count) and count > 0 and is_integer(seconds) and seconds > 0,
       do: limit

  defp validate_rate_limit!(module, _),
    do: fail!(module, "rate_limit must be {requests, seconds}")

  defp validate_flag!(_module, false), do: nil
  defp validate_flag!(_module, flag) when is_binary(flag), do: flag
  defp validate_flag!(module, _), do: fail!(module, "flag must be a string or false")

  defp fail!(module, message) do
    raise ArgumentError, "invalid API route #{inspect(module)}: #{message}"
  end
end
