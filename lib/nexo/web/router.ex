defmodule Nexo.Web.Router do
  use Nexo.Web, :router

  # Public, unattested endpoints: infrastructure health and legal pages.
  pipeline :public do
    plug :accepts, ["json", "html"]
  end

  # Everything else only answers the official Nexo app.
  pipeline :api do
    plug :accepts, ["json"]
    plug Nexo.Web.SecurityHeaders
    plug Nexo.Web.AppCheckPlug
  end

  pipeline :actor_auth do
    plug Nexo.Web.LegacyAuth, :actor
  end

  pipeline :guardian_auth do
    plug Nexo.Web.LegacyAuth, :guardian
  end

  pipeline :directory_access do
    plug Nexo.Web.LegacyAuth, {:directory, []}
  end

  pipeline :directory_admin do
    plug Nexo.Web.LegacyAuth, {:directory, [:admin]}
  end

  scope "/", Nexo.Web do
    pipe_through :public

    get "/health", HealthController, :show
    get "/privacidad", LegalController, :privacy
    get "/privacy", LegalController, :privacy
    # Not "/terms": that path is the students' term list (`GET /terms`).
    get "/terminos", LegalController, :terms
    get "/cookies", LegalController, :cookies
  end

  # Legacy routes the app still calls. The student directory is open to
  # teachers and students alike: the access granted decides, not the account
  # type (see `Nexo.Access.DirectoryAccess`).
  scope "/api/v1/directory", Nexo.Web do
    pipe_through [:api, :actor_auth]

    # The only route that needs no access: it tells whether one has it.
    get "/access", DirectoryController, :access

    scope "/" do
      pipe_through :directory_access

      get "/students", DirectoryController, :index
      get "/students/:codigo", DirectoryController, :show
      get "/schools", DirectoryController, :schools
    end

    # Granting access is for the system administrators.
    scope "/" do
      pipe_through :directory_admin

      get "/grants", DirectoryController, :grants
      put "/grants/:codigo", DirectoryController, :set_grant

      # Guardians: who may see which student with DNI + PIN. Not called by
      # the app, but the only way to provision guardian logins.
      get "/guardians", DirectoryController, :guardians
      put "/guardians/:dni", DirectoryController, :set_guardian
    end
  end

  # Guardians have no university account and only see their children.
  scope "/api/v1/guardian", Nexo.Web do
    pipe_through :api

    post "/login", GuardianController, :login
  end

  scope "/api/v1/guardian", Nexo.Web do
    pipe_through [:api, :guardian_auth]

    get "/students/:codigo", GuardianController, :show
  end

  # Route modules (see `Nexo.Web.Api.Route`), served from the root of the API
  # host with no version prefix. Anything the routes above do not answer
  # falls through here; the dispatcher runs its own security chain.
  forward "/", Nexo.Web.Api.Dispatcher
end
