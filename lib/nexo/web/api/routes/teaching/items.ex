defmodule Nexo.Web.Api.Routes.Teaching.Items do
  @moduledoc "Shared checks of the teaching routes (not a route)."

  @max_items 300

  @doc "A body list of at most #{@max_items} JSON objects."
  def valid?(items), do: length(items) <= @max_items and Enum.all?(items, &is_map/1)

  @doc "`from`/`to` as ISO dates, defaulting to the last `days` days in Lima."
  def range(params, days) do
    today = Nexo.Upstream.Normalize.lima_today()
    to = params[:to] || Date.to_iso8601(today)
    from = params[:from] || today |> Date.add(-days) |> Date.to_iso8601()
    {from, to}
  end
end
