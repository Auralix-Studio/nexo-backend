defmodule Nexo.Academic.Directory.Source do
  @moduledoc """
  Where the student directory comes from.

  Today it is `Nexo.Academic.Directory.SampleSource`: made-up students with
  SIGMA's exact shape. When the university grants its endpoint, a new module
  implementing these four callbacks (for example `UplaSource`, calling the
  endpoint with the service credential) replaces it through configuration:

      config :nexo, :directory_source, Nexo.Academic.Directory.UplaSource

  Nothing else changes: controllers, route modules, access rules and the app
  only talk to `Nexo.Academic.Directory`.

  Shapes, with atom keys:

    * summary — `code, first_name, last_name, school, cycle, status, average,
      credits_approved, credits_total`
    * record — a summary plus `dni, email, phone, faculty, plan, entry_year,
      academic, modules, updated_at`
  """

  @type summary :: map()
  @type record :: map()
  @type page :: %{
          students: [summary()],
          total: non_neg_integer(),
          page: pos_integer(),
          pages: non_neg_integer()
        }

  @doc "A page of students. Options: `:query`, `:school`, `:cycle`, `:page`, `:limit`."
  @callback list(keyword()) :: page()

  @doc "One student's full record, or `nil`."
  @callback get(String.t()) :: record() | nil

  @doc "Schools present in the directory, sorted, for the app's filter."
  @callback schools() :: [String.t()]

  @doc "How many students the source holds."
  @callback count() :: non_neg_integer()
end
