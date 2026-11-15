# Nexo · Backend

API en Elixir/Phoenix para el **acceso especial docente** de Nexo.
Diseño y decisiones: [`../nexo/docs/plan-backend-docentes.md`](../nexo/docs/plan-backend-docentes.md).

| | |
|---|---|
| Runtime | Elixir 1.19 · OTP 28 · Phoenix 1.8 |
| Base de datos | MongoDB (Atlas) |
| Despliegue | Release OTP en contenedor (`Dockerfile` multi-stage) |

## Alcance actual (fases F1 y F2)

- **Login docente** verificado contra SIGMA (`Login/SesionV1`). La contraseña
  UPLA **no se almacena**: se usa una sola vez para confirmar identidad y rol.
  Del login se conserva el *token* de sesión de SIGMA, **cifrado con AES-256-GCM**
  (`Nexo.Security.Vault`), que es lo que permite consultar en nombre del docente.
- **Allowlist en dos pasos.** Todo docente nace `pendiente` — puede autenticarse
  pero no ver datos — hasta que un administrador lo pasa a `autorizado`.
  Suspenderlo revoca sus sesiones de inmediato.
- **Tokens propios.** Acceso firmado de 15 minutos y refresh opaco de 30 días
  con rotación: del refresh solo se guarda su hash, y el usado queda revocado.
- **Datos académicos acotados.** Un docente solo alcanza **sus** secciones:
  cada consulta se valida contra su lista de secciones antes de salir a la red
  y los intentos sobre secciones ajenas se rechazan y se registran. No nos
  apoyamos en que SIGMA también lo limite.
- **Consentimiento del estudiante.** Los datos que SIGMA *no* da al docente
  —horario, pagos, avance— solo existen si el estudiante los comparte desde su
  app. Cada decisión se guarda con fecha, versión del texto e IP, y **revocar
  borra los datos**, no solo marca una casilla.
- **Auditoría.** Cada acción sensible se registra con actor, IP y fecha; las
  lecturas de datos de un alumno quedan además asociadas a su código
  (requisito de la Ley N.º 29733 de protección de datos personales).

## Dónde vive cada dato

Todo en MongoDB; nada en disco local ni en el dispositivo.

| Colección | Contenido |
|---|---|
| `teachers` | Docentes, su estado en la allowlist y su token de SIGMA cifrado |
| `teacher_sections` | Secciones de cada docente — la base del scoping |
| `students` | Solo código y nombre de quien consiente |
| `consents` | Cada decisión de consentimiento, con fecha y versión del texto |
| `student_snapshots` | Datos compartidos, cifrados y borrados al revocar |
| `refresh_tokens` | Hash de los refresh, con expiración automática |
| `audit_log` | Quién accedió a qué y cuándo |

El backend **no consulta la Intranet en nombre del estudiante**: solo recibe lo
que su propia app decide subir. Así cada dato almacenado tiene un
consentimiento asociado y verificable.

## Puesta en marcha

```bash
cp .env.example .env    # completa MONGODB_URI, MONGODB_URI_TEST y ADMIN_API_KEY
mix setup               # dependencias
mix nexo.setup          # crea colecciones e índices en MongoDB
mix phx.server          # http://localhost:4000
```

No hay migraciones: `mix nexo.setup` crea las colecciones con sus índices
(unicidad, TTL de refresh tokens, orden de auditoría) y es idempotente. La
aplicación también los asegura al arrancar.

```bash
mix test        # suite completa
mix precommit   # compila sin warnings, formatea y corre los tests
```

### Por qué hay dos bases

| Base | Uso |
|---|---|
| `nexo` | La real. Es la que usan el servidor y el piloto. |
| `nexo_test` | Solo la suite de tests. |

MongoDB crea las bases con la primera escritura, así que hasta correr
`mix nexo.setup` o levantar el servidor **solo aparece `nexo_test`** en Atlas:
no es que el proyecto viva en una base de pruebas, es que la real aún no se
había escrito.

Las dos están separadas a propósito: la suite **borra sus colecciones en cada
corrida** y un SIGMA simulado sustituye al real, así que jamás toca datos de
verdad ni los servidores de la universidad. `MONGODB_URI_TEST` nunca debe
apuntar a `nexo`.

## Azure

Production runs on Azure Container Apps at `https://api.nexo.aurx.pro`. Steps,
costs and settings: [`deploy/azure/README.md`](deploy/azure/README.md).

## Docker

```bash
docker compose up --build
```

Compose lee las variables de `.env` y exige `SECRET_KEY_BASE`
(`mix phx.gen.secret`). No se levanta ningún motor de base de datos local: la
persistencia vive en Atlas.

## API

| Método | Ruta | Autenticación |
|---|---|---|
| `GET` | `/health` | — |
| `POST` | `/api/v1/auth/teacher/login` · `{usuario, clave}` | — |
| `POST` | `/api/v1/auth/student/login` · `{usuario, clave}` | — |
| `POST` | `/api/v1/auth/refresh` · `{refresh_token}` | — |
| `GET` | `/api/v1/teacher/me` | `Authorization: Bearer` |
| `GET` | `/api/v1/teacher/sections` | Bearer · autorizado |
| `GET` | `/api/v1/teacher/sections/:cle_auto/students` | Bearer · autorizado |
| `GET` | `/api/v1/teacher/sections/:cle_auto/grades?unidad=1` | Bearer · autorizado |
| `GET` | `/api/v1/teacher/sections/:cle_auto/students/:codigo/grades` | Bearer · autorizado |
| `GET` | `/api/v1/teacher/sections/:cle_auto/students/:codigo/shared/:modulo` | Bearer · autorizado · consentido |
| `GET` | `/api/v1/student/consent` | Bearer (estudiante) |
| `PUT` | `/api/v1/student/consent` · `{modulos: []}` | Bearer (estudiante) |
| `DELETE` | `/api/v1/student/consent` | Bearer (estudiante) |
| `GET` | `/api/v1/student/consent/history` | Bearer (estudiante) |
| `PUT` | `/api/v1/student/snapshots/:modulo` · `{datos}` | Bearer (estudiante) |
| `GET` | `/api/v1/directory/access` | Bearer (docente o estudiante) |
| `GET` | `/api/v1/directory/students?q=&escuela=&ciclo=&pagina=&limite=` | Bearer · con acceso |
| `GET` | `/api/v1/directory/students/:codigo` | Bearer · con acceso |
| `GET` | `/api/v1/directory/schools` | Bearer · con acceso |
| `GET` | `/api/v1/directory/grants` | Bearer · administrador |
| `PUT` | `/api/v1/directory/grants/:codigo` · `{estado, nota}` | Bearer · administrador |
| `GET` | `/api/v1/directory/guardians` | Bearer · administrador |
| `PUT` | `/api/v1/directory/guardians/:dni` · `{nombre, estudiantes, nuevo_pin, estado}` | Bearer · administrador |
| `POST` | `/api/v1/guardian/login` · `{dni, pin}` | — |
| `GET` | `/api/v1/guardian/students` | Bearer (apoderado) |
| `GET` | `/api/v1/guardian/students/:codigo` | Bearer (apoderado) · vinculado |
| `GET` | `/api/v1/admin/teachers` | `x-admin-key` |
| `PUT` | `/api/v1/admin/teachers/:id/status` · `{estado}` | `x-admin-key` |
| `GET` | `/api/v1/admin/audit?limit=100` | `x-admin-key` |

`estado` ∈ `pendiente` · `autorizado` · `suspendido`.

## Route modules

New endpoints are served from the root of the API host, with no version
prefix (`https://api.nexo.aurx.pro/status`), one module per endpoint in
`lib/nexo/web/api/routes/`. Each module declares what it is and the rules it
needs; adding an endpoint means adding a file:

```elixir
defmodule Nexo.Web.Api.Routes.Account.Me do
  use Nexo.Web.Api.Route,
    name: "account.me",
    method: :get,
    path: "/me",
    auth: [:teacher, :student, :guardian],
    description: "Who the token belongs to."

  @impl true
  def handle(conn, _params), do: {:ok, %{type: conn.assigns.current_subject.type}}
end
```

`Nexo.Web.Api.Registry` finds every route module when the app starts and
refuses to boot if two routes answer the same request or share a name. In
development, restart the server after adding a route. `Nexo.Web.Api.Dispatcher`
runs each request through the same chain:

| Step | Rejects with |
| --- | --- |
| Security headers (`no-store`, `nosniff`, deny-all CSP, HSTS) | — |
| Per-IP rate limit (3000/min: a campus shares one NAT IP), before any work | `429 rate_limited` |
| Route lookup | `404 not_found`, `405 method_not_allowed` |
| Feature flag | `503 feature_disabled` |
| App attestation (Firebase App Check) | `401 app_not_verified` |
| Authentication and subject type | `401 unauthorized`, `403 forbidden` |
| Per-user (120/min), public per-IP (600/min) and per-route rate limits | `429 rate_limited` + `Retry-After` |
| Param whitelist and validation; per-param limits (login: 10 per user in 10 min) | `422 invalid_params` with every bad field |
| `handle/2` within a 20 s budget; a crash answers with the request id only | `500 internal_error` |

University data is cached per user with single-flight (`Nexo.Infra.Cache`),
and every outbound call goes through `Nexo.Upstream.Guard`: a dedicated Finch
pool (25 connections per host), 10 s per call, 25 calls/s per host and
replica, and a circuit breaker (8 consecutive failures open it for 30 s).
TTLs and limits are listed in `docs/api-models.md`; the tunables are in
`config/runtime.exs` (`MONGODB_POOL_SIZE`, default 15, and others).

Every response has the same shape: `{"ok": true, "data": ...}` or
`{"ok": false, "error": {"code", "message", "details"?}, "request_id"}`.

Admin routes (`x-admin-key`): `GET /admin/catalog` lists every route
with its rules; `GET /admin/flags` and `PUT /admin/flags/:name`
(`{"enabled": false}`) switch a route off at runtime, without a deploy.

### Integrations: calendar and Connect with Nexo

Students can share their **profile and weekly schedule** (never grades or
payments) with other apps. Nothing is shared until they turn it on, and
turning it off deletes the data, the calendar link and every app's access.

* **Calendar link** — `POST /me/calendar` returns a secret
  `/calendar/<key>.ics` URL (plus `webcal://` and Google Calendar links) that
  any calendar app can subscribe to. Weekly events in Lima time until the end
  of the term. Asking again rotates the key; only its hash is stored.
* **Connect with Nexo** — OAuth 2.0 Device Authorization Grant (RFC 8628).
  An app registered by an admin (`POST /admin/integrations/clients`) calls
  `POST /oauth/device` with `scope=profile schedule`, shows the `user_code`,
  and polls `POST /oauth/token`. The student approves inside Nexo
  (`/me/connections/requests/:code`), so no password is ever typed into
  someone else's page. Access tokens last one hour, refresh tokens rotate,
  and data is read at `GET /integrations/profile` and
  `GET /integrations/schedule`. Students revoke apps from Nexo; suspending an
  app cuts all of its tokens.

These third-party routes are the only ones without app attestation; they
require a scoped token instead.

### Only the Nexo app

Both API versions only answer requests carrying a valid **Firebase App
Check** token in `x-firebase-appcheck` (`/health` and the privacy page stay
public). The token proves the call comes from the genuine app on a genuine
device (Play Integrity on Android, App Attest on iOS); a script, a copied APK
or Postman cannot obtain one. It is verified locally against Firebase's
public keys, checking signature, issuer, audience, expiry and app id.

| Variable | Meaning |
| --- | --- |
| `APP_CHECK_MODE` | `enforce` (production default), `monitor` (log only), `off` |
| `FIREBASE_PROJECT_NUMBER` | Firebase project number; without it `enforce` refuses everything |
| `FIREBASE_APP_IDS` | Registered app ids allowed to call the API, comma separated |

Firebase App Check does not support Windows builds: in `enforce` they are
refused too. The client IP is read from `cf-connecting-ip` only when the
direct peer is a trusted proxy (`:trusted_proxies`, localhost by default,
where the Cloudflare tunnel runs).

## Configuración

Ningún secreto se versiona. `.env` está en `.gitignore` y excluido del contexto
de build de Docker; `.env.example` documenta las variables.

| Variable | Uso |
|---|---|
| `MONGODB_URI` | Conexión a MongoDB (obligatoria) |
| `MONGODB_URI_TEST` | Base de pruebas (solo `MIX_ENV=test`) |
| `ADMIN_API_KEY` | Cabecera `x-admin-key` del área de administración |
| `SYSTEM_ADMINS` | Quién puede repartir el acceso al directorio de estudiantes |
| `SECRET_KEY_BASE` | Firma de tokens y cookies (solo producción) |
| `SIGMA_BASE_URL` | Sobrescribe el host de SIGMA |
| `PHX_HOST`, `PORT` | Host público y puerto |

En producción el arranque falla si falta `MONGODB_URI`, `ADMIN_API_KEY` o
`SECRET_KEY_BASE`: es preferible no levantar el servicio a levantarlo con
valores por defecto inseguros.

### Directorio de estudiantes

Apartado aparte del modo estudiante y del modo docente. Muestra la lista de
estudiantes y la ficha de cada uno, y **quien entra no lo decide el tipo de
cuenta sino el acceso concedido**: un estudiante autorizado entra, un docente
sin autorizar no.

El papel del backend aquí es el de portero. El directorio definitivo es
SIGMA/Intranet; mientras no haya permiso institucional para leerlo, la
colección `directory_students` hace de fuente con datos de prototipo que
tienen la forma exacta de los reales (ver `Nexo.Academic.Directory.Prototype`):

```sh
mix nexo.directory 120     # genera y carga el directorio de prototipo
```

Dos niveles de acceso, a propósito distintos:

* **Administradores** (`SYSTEM_ADMINS`) — reparten el acceso y entran siempre.
  Van en el entorno y no en la base porque quien reparte permisos no debe
  poder concedérselos desde dentro de la aplicación.
* **Autorizados** (colección `directory_access`) — los concede un
  administrador desde la app y se revocan en caliente. Revocar no borra el
  documento: lo marca, para que quede el histórico de quién tuvo acceso.

Abrir la ficha de una persona se audita nominalmente (`directory_record_read`),
igual que conceder o revocar un acceso.

### Apoderados (padres y tutores)

Un apoderado no tiene cuenta en SIGMA, así que entra por su propia puerta con
**DNI + PIN** y solo alcanza la ficha de sus hijos. El administrador crea el
vínculo y recibe el PIN una única vez:

```sh
curl -X PUT https://…/api/v1/directory/guardians/44556677 \
  -H "Authorization: Bearer <token de administrador>" \
  -H 'Content-Type: application/json' \
  -d '{"nombre":"Rosa","estudiantes":["U22059D"]}'
# → {"apoderado":{...},"pin":"322628"}   ← anótalo, no se puede volver a leer
```

El DNI identifica pero no autentica —lo conoce cualquiera que tenga el
documento delante—, por eso el PIN es obligatorio. Se guarda derivado con
PBKDF2-SHA256 (120 000 iteraciones, sal por apoderado) y **cinco intentos
fallidos bloquean quince minutos**: seis dígitos se agotan a fuerza bruta en
minutos si nadie lo impide. Un DNI inexistente y un PIN incorrecto devuelven
exactamente la misma respuesta, para no delatar qué DNIs están registrados.

Cada apertura de ficha queda auditada (`guardian_record_read`), igual que las
del directorio, y revocar el vínculo corta el acceso en la siguiente petición.

Respuestas de error propias de los datos académicos:

| Estado | `error` | Significado |
|---|---|---|
| `403` | `no_autorizado` | El docente aún no está en la allowlist |
| `403` | `seccion_ajena` | La sección no le pertenece (queda auditado) |
| `401` | `sesion_sigma_expirada` | Caducó el token de SIGMA: reiniciar sesión |
| `403` | `sin_acceso_directorio` | La cuenta no está autorizada al directorio |
| `403` | `solo_administradores` | Repartir el acceso es cosa de `SYSTEM_ADMINS` |
| `403` | `estudiante_ajeno` | El apoderado no está vinculado a ese estudiante |
| `429` | `acceso_bloqueado` | Demasiados PIN fallidos: espera y reintenta |

## Siguientes fases

- **F3** — Consentimiento del estudiante desde la app y snapshots de horario,
  pagos y avance académico.
- **F4** — Notificaciones y avisos por sección.
