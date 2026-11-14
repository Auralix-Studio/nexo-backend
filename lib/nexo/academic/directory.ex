defmodule Nexo.Academic.Directory do
  @moduledoc """
  The student directory, read through the configured source (see
  `Nexo.Academic.Directory.Source`).

  The backend only decides who may read it; the data itself comes from the
  source: sample students today, the university's endpoint once it exists.
  """
  alias Nexo.Academic.Directory.SampleSource

  @doc "The module serving the directory (`:directory_source`)."
  def source, do: Application.get_env(:nexo, :directory_source, SampleSource)

  def list(opts \\ []), do: source().list(opts)
  def get(code), do: source().get(code)
  def schools, do: source().schools()
  def count, do: source().count()

  @doc "Loads sample students (`mix nexo.directory`). Only for the sample source."
  defdelegate replace_all(students), to: SampleSource

  defdelegate terms_for(code, first_name, last_name), to: SampleSource
end
