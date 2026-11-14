defmodule Nexo.Web.Api.Registry do
  @moduledoc """
  Finds every `Nexo.Web.Api.Route` module in the application and builds the
  routing table, kept in `:persistent_term` for lock-free reads.

  It is built when the application starts. Two routes that would answer
  the same request, or share a name, stop the boot with an error instead of
  one silently shadowing the other. In development, restart the server
  after adding a new route module.
  """
  alias Nexo.Web.Api.Spec

  @key {__MODULE__, :routes}

  @spec routes() :: [Spec.t()]
  def routes do
    case :persistent_term.get(@key, nil) do
      nil -> reload!()
      routes -> routes
    end
  end

  @spec reload!() :: [Spec.t()]
  def reload! do
    routes = discover() |> build!()
    :persistent_term.put(@key, routes)
    routes
  end

  @doc "Every route spec compiled into the `:nexo` application."
  def discover do
    {:ok, modules} = :application.get_key(:nexo, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :__route__, 0),
        do: module.__route__()
  end

  @doc """
  Checks for collisions and sorts the table so literal segments win over
  parameters (`/students/search` before `/students/:code`).
  """
  @spec build!([Spec.t()]) :: [Spec.t()]
  def build!(specs) do
    specs
    |> Enum.group_by(&{&1.method, shape(&1.segments)})
    |> Enum.each(fn
      {_, [_single]} ->
        :ok

      {{method, _}, duplicates} ->
        raise ArgumentError,
              "API routes #{inspect(Enum.map(duplicates, & &1.module))} all answer " <>
                "#{method |> to_string() |> String.upcase()} #{hd(duplicates).path}"
    end)

    specs
    |> Enum.group_by(& &1.name)
    |> Enum.each(fn
      {_, [_single]} ->
        :ok

      {name, duplicates} ->
        raise ArgumentError,
              "API routes #{inspect(Enum.map(duplicates, & &1.module))} share the name #{name}"
    end)

    Enum.sort_by(specs, &{shape(&1.segments), &1.path, &1.method})
  end

  defp shape(segments) do
    Enum.map(segments, fn
      {:literal, value} -> {0, value}
      {:param, _} -> {1, ""}
    end)
  end

  @doc """
  Finds the route for a request. Returns `{:ok, spec, path_params}`,
  `{:error, :not_found}` or `{:error, {:method_not_allowed, allowed}}`.
  """
  def match(routes, method, path_info) do
    candidates =
      for spec <- routes,
          {:ok, params} <- [match_path(spec.segments, path_info, %{})],
          do: {spec, params}

    case Enum.find(candidates, fn {spec, _} -> spec.method == method end) do
      {spec, params} ->
        {:ok, spec, params}

      nil when candidates == [] ->
        {:error, :not_found}

      nil ->
        allowed = candidates |> Enum.map(fn {spec, _} -> spec.method end) |> Enum.uniq()
        {:error, {:method_not_allowed, allowed}}
    end
  end

  defp match_path([], [], params), do: {:ok, params}

  defp match_path([{:literal, value} | rest], [value | path], params),
    do: match_path(rest, path, params)

  defp match_path([{:param, name} | rest], [value | path], params),
    do: match_path(rest, path, Map.put(params, Atom.to_string(name), value))

  defp match_path(_segments, _path, _params), do: :error
end
