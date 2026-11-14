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

  pipeline :teacher_auth do
    plug Nexo.Web.AuthPlug
  end

  pipeline :student_auth do
    plug Nexo.Web.StudentAuthPlug
  end

  pipeline :teacher_authorized do
    plug Nexo.Web.RequireAuthorizedPlug
  end

  pipeline :actor_auth do
    plug Nexo.Web.ActorPlug
  end

  pipeline :guardian_auth do
    plug Nexo.Web.GuardianAuthPlug
  end

  pipeline :directory_access do
    plug Nexo.Web.RequireDirectoryPlug
  end

  pipeline :directory_admin do
    plug Nexo.Web.RequireDirectoryPlug, [:admin]
  end

  pipeline :admin do
    plug Nexo.Web.AdminPlug
  end

  scope "/", Nexo.Web do
    pipe_through :public

    get "/health", HealthController, :show
    get "/privacidad", LegalController, :privacy
    get "/privacy", LegalController, :privacy
  end

  scope "/api/v1", Nexo.Web do
    pipe_through :api

    post "/auth/teacher/login", AuthController, :teacher_login
    post "/auth/student/login", AuthController, :student_login
    post "/auth/refresh", AuthController, :refresh
  end

  # Lado estudiante: gestiona su consentimiento y sube sus propios datos.
  scope "/api/v1/student", Nexo.Web do
    pipe_through [:api, :student_auth]

    get "/consent", ConsentController, :show
    put "/consent", ConsentController, :update
    delete "/consent", ConsentController, :revoke
    get "/consent/history", ConsentController, :history
    put "/snapshots/:modulo", ConsentController, :put_snapshot
  end

  scope "/api/v1/teacher", Nexo.Web do
    pipe_through [:api, :teacher_auth]

    get "/me", TeacherController, :me

    # Datos académicos: exigen allowlist activa y quedan acotados a las
    # secciones del propio docente (ver `Nexo.Academic.Teaching`).
    scope "/" do
      pipe_through :teacher_authorized

      get "/sections", SectionController, :index
      get "/sections/:cle_auto/students", SectionController, :students
      get "/sections/:cle_auto/grades", SectionController, :grades
      get "/sections/:cle_auto/students/:codigo/grades", SectionController, :student_grades

      # Datos que el estudiante compartió voluntariamente: sin consentimiento
      # vigente no existen para el docente.
      get "/sections/:cle_auto/students/:codigo/shared/:modulo",
          SectionController,
          :student_snapshot
    end
  end

  # Directorio de estudiantes: apartado propio, abierto a docentes y a
  # estudiantes por igual. Lo que decide no es el tipo de cuenta sino el
  # acceso concedido (ver `Nexo.Access.DirectoryAccess`).
  scope "/api/v1/directory", Nexo.Web do
    pipe_through [:api, :actor_auth]

    # Única ruta que no exige acceso: sirve para saber si se tiene.
    get "/access", DirectoryController, :access

    scope "/" do
      pipe_through :directory_access

      get "/students", DirectoryController, :index
      get "/students/:codigo", DirectoryController, :show
      get "/schools", DirectoryController, :schools
    end

    # Repartir el acceso es cosa de los administradores del sistema.
    scope "/" do
      pipe_through :directory_admin

      get "/grants", DirectoryController, :grants
      put "/grants/:codigo", DirectoryController, :set_grant

      # Apoderados: quién puede ver a qué estudiante con DNI + PIN.
      get "/guardians", DirectoryController, :guardians
      put "/guardians/:dni", DirectoryController, :set_guardian
    end
  end

  # Acceso de apoderados: sin cuenta de la UPLA, solo la ficha de sus hijos.
  scope "/api/v1/guardian", Nexo.Web do
    pipe_through :api

    post "/login", GuardianController, :login
  end

  scope "/api/v1/guardian", Nexo.Web do
    pipe_through [:api, :guardian_auth]

    get "/students", GuardianController, :students
    get "/students/:codigo", GuardianController, :show
  end

  scope "/api/v1/admin", Nexo.Web do
    pipe_through [:api, :admin]

    get "/teachers", AdminController, :list_teachers
    put "/teachers/:id/status", AdminController, :set_teacher_status
    get "/audit", AdminController, :audit
  end

  # Route modules (see `Nexo.Web.Api.Route`), served from the root of the API
  # host with no version prefix. Anything the routes above do not answer
  # falls through here; the dispatcher runs its own security chain.
  forward "/", Nexo.Web.Api.Dispatcher
end
