defmodule Nexo do
  @moduledoc """
  Backend of Nexo, the UPLA academic app. Everything lives under `Nexo`,
  grouped by area so each module is found by its name:

    * `Nexo.Infra` — database, in-memory cache, rate limiter, feature flags.
    * `Nexo.Security` — session tokens, app attestation, encryption, audit log.
    * `Nexo.People` — teachers, students and guardians.
    * `Nexo.Access` — who may see what: directory grants and student consent.
    * `Nexo.Academic` — teaching sections and the student directory.
    * `Nexo.Sigma` — the client for the university's SIGMA API.
    * `Nexo.Web` — HTTP: endpoint, router, plugs, the legacy `/api/v1`
      controllers and the route modules (`Nexo.Web.Api`).

  Only `Nexo.Web` knows about HTTP; the other areas can be called from a
  controller, a route module or a mix task alike.
  """
end
