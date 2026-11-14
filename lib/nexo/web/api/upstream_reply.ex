defmodule Nexo.Web.Api.UpstreamReply do
  @moduledoc "Turns `{:ok, data, meta}` / `{:error, reason}` from upstream-backed modules into route replies."

  @doc "Like `reply/1` for modules that answer `{:ok, data, sources}` (per-source status)."
  def with_sources({:ok, data, sources}), do: reply({:ok, data, %{sources: sources}})
  def with_sources(error), do: reply(error)

  def reply({:ok, data, meta}), do: {:ok, data, Map.put(meta, :fetched_at, DateTime.utc_now())}

  def reply({:error, :unknown_term}),
    do: {:error, 404, :unknown_term, "The student has no such term."}

  def reply({:error, :unknown_course}),
    do: {:error, 404, :unknown_course, "The term has no course with that id."}

  def reply({:error, :unknown_section}),
    do: {:error, 404, :unknown_section, "The teacher has no section with that id."}

  def reply({:error, :unknown_unit}),
    do: {:error, 422, :unknown_unit, "The section has no such unit."}

  def reply({:error, :unknown_grade_type}),
    do: {:error, 422, :unknown_grade_type, "The unit has no such grade type."}

  def reply({:error, :unknown_class}),
    do: {:error, 404, :unknown_class, "There is no class with that id today."}

  def reply({:error, :rejected}),
    do: {:error, 422, :rejected_by_university, "The university system did not accept the change."}

  def reply({:error, :invalid_items}),
    do: {:error, 422, :invalid_items, "The list must hold at most 300 objects."}

  def reply({:error, :reauth_required}), do: {:error, :reauth_required}
  def reply({:error, _}), do: {:error, :upstream_unavailable}
end
