# Nexo API — data models

The app talks only to `https://api.nexo.aurx.pro`. The backend reads SIGMA,
the Intranet and the Language Center (Idiomas), fixes their quirks, and
returns the models below. The app never sees an upstream field name, a
positional array or an upstream id it has to interpret.

Status (Nov 2026): **implemented** — module 1 (`POST /auth/login`,
`POST /auth/refresh`, `POST /auth/logout`, `GET /profile`, `GET /terms`),
module 2 (`GET /schedule`, `GET /languages`), module 3 (`GET /grades`,
`GET /grades/{term}/courses/{id}`, `GET /grades/summary`, `GET /curriculum`),
module 4 (`GET /payments`, `GET /payments/schedule`,
`GET /payments/history`), module 6 (`GET /enrollment`, `GET /publications`,
`GET /wifi`) and module 5 (teacher: `GET /teaching/sections`,
`…/{id}/students`, `…/{id}/grade-units`, `PUT …/{id}/grades`,
`GET`/`POST …/{id}/attendance`, `PATCH …/{id}/attendance/{session}`,
`GET /teaching/virtual-classes`, `POST /teaching/virtual-classes/{id}/punch`,
`GET /teaching/punches`, `GET /teaching/compliance`, `GET /teaching/me`,
`GET /teaching/server-time`, `GET /teaching/sections/{id}/report`).
The rest is the agreed contract, built module by module. Values in examples
are made up.

## 1. Conventions

| Rule | Example |
| --- | --- |
| Envelope on every response | `{"ok": true, "data": {…}, "meta": {…}}` / `{"ok": false, "error": {"code", "message", "details"?}, "request_id"}` |
| English `snake_case` keys, same name for the same concept in every source | `term`, `course`, `credits`, `final_grade` |
| Real types | `3`, not `"3.000"`; `true`, not `"True"`/`"1"` |
| Missing value is `null` | never `""`, `" "`, `"-"`, `"--"`, `"No hay datos"` or a fake `0` |
| Empty list is `[]` | never a sentinel row |
| Dates ISO 8601; date-times with Lima offset | `"2026-04-28"`, `"2026-10-07T12:59:09-05:00"` |
| Times `HH:MM`, 24 h, Lima wall clock | `"08:00"` |
| Weekdays ISO: 1 Monday … 7 Sunday | `"weekday": 1` |
| Grades on the 0–20 scale, with the scale stated | workshops reported on 0–100 are converted |
| Money as numbers with an ISO currency | `"currency": "PEN"`, `"amount": 522.5` |
| Closed sets are lowercase English words | `"status": "in_progress"` |
| Terms have one id format | `"2026-1"` (year-number); label `"2026-I"` / `"2026-II"` |
| Lists have a stated order | terms newest first, payments by due date, history newest first |
| `meta` says where data came from | `{"source": "intranet", "fetched_at": "…", "cached": false}` |

Upstream ids needed to write back to SIGMA (`cleAuto`, attendance id lists,
`matricula_asignatura_id`, `cod_cursal`, `plan`, `tipoCalif`, `idNota`…)
stay in the backend. The app addresses everything by Nexo ids.

## 2. Endpoints

| Route | Model | Upstream today | Replaces in the app |
| --- | --- | --- | --- |
| `POST /auth/login` | Session | SIGMA `Login/SesionV1` (+ Intranet and Idiomas sessions opened server-side) | `SigmaRepository.login`, Intranet/Idiomas logins |
| `POST /auth/refresh`, `POST /auth/logout` | Session | — | `SessionService` token handling |
| `POST /auth/password` | — | SIGMA `Login/ChangePassword` | `changePassword` |
| `GET /profile` | StudentProfile | Intranet `datosEstudianteMatriculado` + certificate, SIGMA `MostrarInfoEstudiante`, `MostrarNotasResumen` | `infoEstudiante` ×2, `datosEntidad`, `notasResumen` |
| `GET /terms` | Term[] | Intranet `consultarPeriodosMatriculados`, SIGMA `ListarPeriodosEstudiante` | `periodos*` |
| `GET /schedule?term=` | Schedule | Intranet `verhorariomatriz…`, SIGMA `ListarHorariosEstudianteIntranet`, Idiomas | `schedule`, `horarioMatriculados`, Idiomas merge |
| `GET /grades?term=` | TermGrades | Intranet `consultarconstanciaNotasDetallado` (both shapes), SIGMA `ListarNotasEstudianteIntranet` | `boleta`, `boletaLegacy`, `notasPeriodo` |
| `GET /grades/{term}/courses/{course_id}` | CourseGrades | Intranet `consultarDetalleBoletaNotas` | `detalleCurso` |
| `GET /grades/summary` | AcademicSummary | SIGMA `MostrarNotasResumen`, `ListarPromediosResumen`, `MostrarConteoNotas` | `promediosResumen`, `gradesCount`, `promedioAcumulado` |
| `GET /curriculum` | Curriculum | Intranet `consultarProgresoCurricular` | `recordAcademico` |
| `GET /enrollment?term=` | Enrollment | Intranet `consultarConstanciaMatriculaEstudiante` | `constanciaMatricula` (PDF data) |
| `GET /payments` | Payments | Intranet `consultarPensiones`, `consultartotalPensiones`, `consultarMatricula`, `consultarTasas` | `pensiones*`, `matriculaVencida`, `tasasIntranet` |
| `GET /payments/schedule?term=` | PaymentSchedule | Intranet `consultarCuotasEstudiante` | `cronogramaPagos` |
| `GET /payments/history` | PaymentHistory | Intranet `consultarUltimasOperaciones` | `historicoPagos` |
| `GET /languages` | LanguageCourses | Idiomas `ListarMisAsignaturasMatriculadas`, `NotasInglesXDetMatriculaId` | `IdiomasRepository` |
| `GET /publications` | Publication[] | SIGMA `ListarPublicaciones` | `publications` |
| `GET /wifi` | Wifi | SIGMA `ObtenerWifiUsuario` | `wifiCredencial` |
| `GET /teaching/me` | TeacherProfile | SIGMA `GetDatosEntidad` | `infoDocente` |
| `GET /teaching/sections` | TeacherSection[] | SIGMA `GetAsignaturaDocente` ×2 (Notas + Asistencia), merged | `asignaturas` |
| `GET /teaching/sections/{id}/students` | Roster | SIGMA `NotasEstudianteResumenV1` | `estudiantesSeccion`, `notasResumen` |
| `GET /teaching/sections/{id}/grade-units` | GradeUnit[] | SIGMA `getTipoUnidadesV2`, `getTipoNota` | `unidadesNotas`, `tiposNota` |
| `PUT /teaching/sections/{id}/grades` | GradeWrite → result | SIGMA `InsertarNotas` / `UpdateNota` | `insertarNotas`, `actualizarNotas` |
| `GET /teaching/sections/{id}/attendance` | AttendanceSheet | SIGMA `GetAsistencia`, `getTipoUnidadesV2` | `asistencia`, `unidadesAsistencia` |
| `POST /teaching/sections/{id}/attendance` | AttendanceWrite | SIGMA `InsertaRegistroAsistencia`, `GetHora` | `registrarAsistencia`, `horaServidor` |
| `PATCH /teaching/sections/{id}/attendance/{session}` | AttendanceWrite | SIGMA `ActualizarRegistroAsistencia` | `actualizarAsistencia` |
| `GET /teaching/sections/{id}/report?format=pdf\|xlsx` | file | SIGMA `GetReporteAuxiliar` | `reporteAuxiliar` |
| `GET /teaching/virtual-classes`, `POST …/{id}/punch` | VirtualClass[] | SIGMA `getAsistenciaDocente`, `InsertaRegistroAsistenciaDocente` | `clasesVirtuales`, `marcarVirtual` |
| `GET /teaching/punches?from=&to=` | Punch[] | SIGMA `getHistorialMarcacion` | `historialMarcacion` |
| `GET /teaching/compliance?from=&to=` | Compliance[] | SIGMA `getAsistenciaDiaria` (all pages) | `cumplimiento` |

Already live: `/status`, `/me`, `/me/shared`, `/me/calendar`, `/me/connections/*`,
`/oauth/*`, `/integrations/*`, `/admin/*`, and the legacy `/api/v1` routes the
app still calls: `/api/v1/directory/*` (access, students, schools, grants and
guardian links) and `/api/v1/guardian/login`, `/api/v1/guardian/students/{code}`.

## 3. Student models

### Session (`POST /auth/login`)

```json
{
  "access_token": "…",
  "refresh_token": "…",
  "expires_in": 900,
  "user": {
    "code": "U01025B",
    "role": "student",
    "name": { "first": "Ana", "last": "Rojas Quispe", "full": "Ana Rojas Quispe" },
    "photo_url": "https://academico.upla.edu.pe/…"
  },
  "sources": { "sigma": "ok", "intranet": "ok", "languages": "unavailable" }
}
```

`role` is `student` or `teacher` (from SIGMA `isDocente`). `sources` tells the
app which upstreams are up, so a SIGMA outage does not look like bad
credentials.

### StudentProfile (`GET /profile`)

```json
{
  "code": "U01025B",
  "name": { "first": "Ana", "last": "Rojas Quispe", "full": "Ana Rojas Quispe" },
  "faculty": "Ingeniería",
  "career": "Ingeniería de Sistemas y Computación",
  "specialty": null,
  "campus": "Huancayo",
  "modality": "in_person",
  "study_plan": "2015",
  "current_cycle": 7,
  "enrolled": true,
  "last_enrollment": "2026-2",
  "credits": { "approved": 168, "required": 220, "enrolled_this_term": 22 },
  "average": { "cumulative": 14.12 }
}
```

`credits.approved` comes from SIGMA (`creditoAprobado` / `creditosAprobados`).
The Intranet value the app uses today is the **current term's enrolled
credits**, which is now `enrolled_this_term`. Campus codes (`HU`, `LM`…) are
expanded; `current_cycle` is an integer whatever the padding.

### Term (`GET /terms`)

```json
[
  { "id": "2026-2", "year": 2026, "number": 2, "label": "2026-II", "active": true },
  { "id": "2026-1", "year": 2026, "number": 1, "label": "2026-I", "active": false }
]
```

Newest first. `active` comes from SIGMA's `activo`; the Intranet order is only
a fallback. A number other than 1 or 2 keeps its own label (`"2011-0"`).

### Schedule (`GET /schedule?term=2026-2`)

```json
{
  "term": { "id": "2026-2", "label": "2026-II" },
  "classes": [
    {
      "id": "c9f1…",
      "course": { "code": "IS-301", "name": "Base de Datos", "nrc": "341119" },
      "section": "A1",
      "kind": "theory",
      "weekday": 1,
      "start": "08:00",
      "end": "09:45",
      "duration_minutes": 105,
      "room": { "campus": "Huancayo", "building": "Pabellón H", "name": "H 302", "capacity": 40 },
      "teacher": "Docente Ejemplo",
      "modality": "in_person",
      "source": "university"
    },
    {
      "id": "lang-1234-1",
      "course": { "code": "ING-B1", "name": "Inglés B1", "nrc": null },
      "section": "B",
      "kind": "language",
      "weekday": 1,
      "start": "19:00",
      "end": "20:30",
      "duration_minutes": 90,
      "room": { "campus": "Virtual", "building": null, "name": "Aula 5", "capacity": null },
      "teacher": "Centro de Idiomas",
      "modality": "virtual",
      "source": "languages"
    }
  ]
}
```

`kind`: `theory | practice | lab | language`. Labs are kept (today the
Intranet parser turns them into theory). The teacher is read from SIGMA's
`docente` (the app reads a non-existent `teacher` key today). Language Center
classes for the current month are merged here.

### TermGrades (`GET /grades?term=2026-1`)

One shape for both upstream models (`competencies` from 2026-1 on, `legacy`
before).

```json
{
  "term": { "id": "2026-1", "label": "2026-I" },
  "model": "competencies",
  "scale": { "max": 20, "passing": 10.5 },
  "average": { "value": 13.42, "official": 13.0, "credits": 22 },
  "courses": [
    {
      "id": "8f2c…",
      "code": "IS-301",
      "name": "Base de Datos",
      "section": "A1",
      "cycle": 7,
      "credits": 3,
      "type": "mandatory",
      "attendance_percent": 95,
      "status": "in_progress",
      "grade": { "current": 11.6, "official": 12 },
      "makeup_exam": null,
      "rank": null,
      "closed": false
    }
  ]
}
```

- `grade.current` is the real average from the units (upstream rounds 11.6
  to 12 and counts ungraded units as 0); `grade.official` is what the
  university shows. Workshop grades on 0–100 come back on 0–20.
- `status`: `in_progress | passed | failed | not_graded`.
- `type`: `mandatory | elective | …` (from `TN/TA/TT/TE/TP`).
- `closed` is read correctly from both sources (SIGMA `"True"`, Intranet
  `"1"`; today Intranet rows are never closed).
- `rank` (legacy only): `{ "position": 3, "of": 40 }`.
- `average.value` is the credit-weighted term average from `grade.current`.
- `id` is the course code; the university's enrollment id stays in the
  backend.
- While a competencies course is in progress, upstream's average column holds
  the points accumulated so far (14 on a 20 % unit shows as 2.8) and
  `grade.official` is that number rounded, as the university shows it. The
  backend loads the detail of in-progress courses to compute `grade.current`.
- `units` comes inline when the backend already has it (every legacy course,
  in-progress competencies courses), `null` otherwise. Legacy units also carry
  `practices_average` and `work_average`.

### CourseGrades (`GET /grades/2026-1/courses/{id}`)

```json
{
  "course": { "id": "8f2c…", "code": "IS-301", "name": "Base de Datos", "credits": 3 },
  "units": [
    {
      "number": 1,
      "name": "Unidad 1",
      "weight_percent": 25,
      "average": 14.5,
      "evidences": [
        { "type": "knowledge", "label": "Evidencia de conocimiento", "weight_percent": 30, "grade": 15 },
        { "type": "performance", "label": "Evidencia de desempeño", "weight_percent": 40, "grade": 14 },
        { "type": "product", "label": "Evidencia de producto", "weight_percent": 30, "grade": null }
      ]
    }
  ],
  "makeup_exam": null,
  "final": { "current": 11.6, "official": 12, "status": "in_progress" },
  "projection": { "target": 10.5, "needed_average": 9.8, "status": "reachable" }
}
```

Legacy terms use the same shape: each half is a unit, and practices,
individual work, project and partial exam are evidences
(`practice | individual_work | project | partial_exam`). Duplicate upstream
tables are dropped. `projection.status`: `no_data | closed | already_passed |
reachable | impossible`.

### AcademicSummary (`GET /grades/summary`)

```json
{
  "cumulative_average": 14.12,
  "credits": { "approved": 168, "required": 220 },
  "terms": [
    { "term": "2026-1", "average": 13.8 },
    { "term": "2025-2", "average": 14.4 }
  ],
  "current_term": { "term": "2026-2", "partial_average": 12.9, "passed": 3, "failed": 1, "pending": 2 }
}
```

Numbers that SIGMA sends as strings come back as numbers; an empty summary is
`null` fields, not zeros.

### Curriculum (`GET /curriculum`)

```json
{
  "plan": "2015",
  "career": "Ingeniería de Sistemas y Computación",
  "progress": { "completed_courses": 52, "pending_courses": 10, "credits_completed": 168, "credits_total": 220 },
  "courses": [
    { "code": "IS-101", "name": "Introducción a la Ingeniería", "cycle": 1, "credits": 3, "type": "mandatory", "status": "completed", "grade": 15, "attempts": 1 },
    { "code": "IS-901", "name": "Tesis I", "cycle": 9, "credits": 4, "type": "mandatory", "status": "pending", "grade": null, "attempts": 0 }
  ]
}
```

Reads cycle and credits from the right columns (today the cycle is taken
from the credits column and credits always come out 0).

### Enrollment (`GET /enrollment?term=2026-2`)

```json
{
  "term": { "id": "2026-2", "label": "2026-II" },
  "student": { "code": "U01025B", "name": "Ana Rojas Quispe", "photo_url": "…" },
  "faculty": "Ingeniería",
  "career": { "label": "Carrera", "name": "Ingeniería de Sistemas y Computación" },
  "specialty": null,
  "study_plan": "2015",
  "cycle": 7,
  "modality": "in_person",
  "courses": [ { "code": "IS-301", "name": "Base de Datos", "cycle": 7, "section": "A1", "credits": 3 } ],
  "total_credits": 22,
  "issued_at": "2026-11-13"
}
```

Data for the enrollment certificate PDF. The PDF is still drawn in the app.

### Payments (`GET /payments`)

```json
{
  "currency": "PEN",
  "summary": {
    "pending_total": 1567.5,
    "overdue_total": 522.72,
    "fees_total": 20.0,
    "next_due": { "id": "2026-1-cuota-03", "due_date": "2026-06-12", "total": 522.5 }
  },
  "overdue": [
    {
      "id": "2026-1-cuota-02",
      "kind": "tuition_installment",
      "label": "Cuota 02",
      "term": "2026-1",
      "number": 2,
      "due_date": "2026-05-20",
      "amount": 522.5,
      "late_fee": 0.22,
      "total": 522.72,
      "status": "overdue",
      "note": null
    }
  ],
  "pending": [
    {
      "id": "2026-1-cuota-03",
      "kind": "tuition_installment",
      "label": "Cuota 03",
      "term": "2026-1",
      "number": 3,
      "due_date": "2026-06-12",
      "amount": 522.5,
      "late_fee": 0,
      "total": 522.5,
      "status": "pending",
      "note": null
    },
    {
      "id": "2026-1-cuota-03-credits",
      "kind": "credit_extension",
      "label": "Ampliación de créditos",
      "term": "2026-1",
      "number": 3,
      "due_date": "2026-06-13",
      "amount": 124.0,
      "late_fee": 0,
      "total": 124.0,
      "status": "pending",
      "note": "4 créditos × S/ 31.00"
    }
  ],
  "fees": [
    { "label": "Seguro universitario", "amount": 20.0, "note": null }
  ]
}
```

- `status` is computed by the backend from `due_date` in Lima time
  (`pending | due_soon | overdue`), not from which endpoint answered.
- `kind`: `tuition_installment | credit_extension | enrollment | discount | fee`.
  Overdue enrollment (no due date) is `kind: "enrollment"`, `due_date: null`.
- `summary.pending_total` is everything owed (overdue included) and is what
  the home tile should show; today the app leaves overdue debt out.
  `overdue_total` is the overdue part.
- `due_soon` means due within 7 days. Lists are sorted by due date; overdue
  enrollment (no date) comes first.
- Charge ids are stable: `"{term}-cuota-{NN}"`, plus `-credits` for a credit
  extension, `enrollment-…` and `discount-…` for the others.
- All three upstream date formats become ISO.

### PaymentSchedule (`GET /payments/schedule`)

```json
{
  "term": { "id": "2026-1", "label": "2026-I" },
  "currency": "PEN",
  "term_total": 2750.0,
  "installments": [
    { "number": 1, "amount": 550.0, "due_date": "2026-04-28" },
    { "number": 2, "amount": 550.0, "due_date": "2026-05-20" }
  ],
  "generated_at": "2026-03-31T17:34:33-05:00"
}
```

An empty schedule is `"installments": []` (today a `No hay datos` row
becomes one blank installment). Upstream only serves the current term's
plan, so there is no `term` parameter; `term` is the active term.

### PaymentHistory (`GET /payments/history`)

```json
{
  "currency": "PEN",
  "operations": [
    {
      "id": "0002-002368016",
      "date": "2026-05-20",
      "term": "2026-1",
      "place": "Caja Huancayo",
      "voucher": "B010-00908656",
      "bank_reference": "CMAC AG. 000076 OP. 569674",
      "total": 523.0,
      "items": [
        { "concept": "Cuota 01 Pensiones de enseñanza", "kind": "payment", "amount": 550.0 },
        { "concept": "Cuota 01 Descuento extraordinario 5%", "kind": "discount", "amount": -27.5 },
        { "concept": "Moras y recargos", "kind": "late_fee", "amount": 0.5 }
      ]
    }
  ]
}
```

Upstream splits one bank operation into several rows; they are grouped by
serial and number (`id` is `"serial-number"`), items in upstream order. A
single operation can carry more than one voucher, so each item also has its
own `voucher`; the operation's `voucher` is the first one.

### LanguageCourses (`GET /languages`)

```json
{
  "courses": [
    {
      "id": "1234",
      "language": "Inglés",
      "course": "Inglés B1",
      "section": "B",
      "modality": "virtual",
      "period": { "year": 2026, "month": 11 },
      "current": true,
      "shift": "Noche",
      "room": "Aula 5",
      "schedule": [ { "weekday": 1, "start": "19:00", "end": "20:30" } ],
      "grades": { "items": [15, 14, null, null, null, null], "average": 14.5 }
    }
  ]
}
```

Grades are fetched per course on the server; `0` becomes `null`.

### Publication and Wifi

```json
{ "id": 812, "kind": "image", "url": "…", "adaptive_url": null, "link_url": null, "button_text": null, "downloadable": true, "width": 1080, "height": 1350 }
```

```json
{ "user": "u01025b", "password": "…" }
```

`GET /publications` returns a list of the first shape (entries without a URL
are dropped; `"1080x1350"` becomes `width`/`height`). `GET /wifi` returns the
second; it is read from SIGMA on every request, never cached or logged, sent
with `cache-control: no-store`, and rate-limited to 10 per minute. Both are
`null` fields when SIGMA has no credential.

Module 6 status: `GET /enrollment`, `GET /publications` and `GET /wifi` are
implemented (student only; the teacher app shows neither).

## 4. Teacher models

### TeacherSection (`GET /teaching/sections`)

The two SIGMA lists (grades and attendance, with different ids) are merged
and deduplicated on the server; the app gets one section with one id.

```json
{
  "id": "sec_7b1e…",
  "term": "2026-2",
  "nrc": "341119",
  "course": { "code": "341119", "name": "Metodología del Estudio Universitario" },
  "section": "A2",
  "career": "Arquitectura",
  "modality": "in_person",
  "cycle": 1,
  "elective": false,
  "enrolled": 38,
  "campus": "Huancayo",
  "room": { "building": "Pabellón K", "name": "Taller de Dibujo 1", "capacity": 40 },
  "schedule": [ { "weekday": 2, "start": "16:45", "end": "19:00", "kind": "theory" } ]
}
```

### Roster (`GET /teaching/sections/{id}/students`)

```json
{
  "section_id": "sec_7b1e…",
  "students": [
    {
      "code": "U05079C",
      "name": "Apellidos Nombres",
      "photo_url": "…",
      "attendance_percent": 82.5,
      "at_risk": false,
      "suspended": false,
      "final_grade": 13.0,
      "units": [
        {
          "unit_id": 101,
          "name": "Unidad 1",
          "weight_percent": 25,
          "average": 14.0,
          "evaluations": [
            { "type_id": 11, "type": "knowledge", "abbr": "EV", "weight_percent": 30, "grades": [15, null] }
          ]
        }
      ]
    }
  ]
}
```

`grades` is the list of columns for that evaluation type (the upstream
column is only the array position). `final_grade: null` means "no grades yet",
not a fail.

### GradeUnit (`GET /teaching/sections/{id}/grade-units`)

```json
[
  {
    "unit_id": 101,
    "name": "Unidad 1",
    "open": true,
    "types": [
      { "type_id": 11, "abbr": "EV", "name": "Evidencia de conocimiento", "max": 20, "passing": 10.5, "max_columns": 2, "color": "#4F46E5" }
    ]
  }
]
```

### GradeWrite (`PUT /teaching/sections/{id}/grades`)

```json
{
  "unit_id": 101,
  "type_id": 11,
  "column": 0,
  "grades": [ { "student": "U05079C", "value": 15.5 } ]
}
```

The backend decides insert vs update per student (upstream `InsertarNotas` /
`UpdateNota`), validates `0 ≤ value ≤ max` with two decimals, skips unchanged
values, and answers per student:

```json
{ "saved": 37, "unchanged": 1, "failed": [ { "student": "U03322B", "reason": "unit_closed" } ] }
```

### AttendanceSheet (`GET /teaching/sections/{id}/attendance`)

```json
{
  "section_id": "sec_7b1e…",
  "units": [ { "unit_id": 201, "name": "Unidad 2", "open": true } ],
  "server_time": "2026-10-07T12:59:09-05:00",
  "sessions": [
    { "id": "2026-10-29T14:41:00", "taken_at": "2026-10-29T14:41:00-05:00", "unit_id": 201, "present": 30, "absent": 6, "justified": 2 }
  ],
  "students": [
    {
      "code": "U05079C",
      "name": "Apellidos Nombres",
      "percent": 82.5,
      "at_risk": false,
      "suspended": false,
      "marks": [ { "session": "2026-10-29T14:41:00", "state": "present" } ]
    }
  ]
}
```

`state`: `none | present | absent | justified | suspended`. Units hidden by
SIGMA's internal ids are filtered on the server.

### AttendanceWrite

`POST /teaching/sections/{id}/attendance` (new session, timestamp from SIGMA's
server clock):

```json
{ "unit_id": 201, "marks": [ { "student": "U05079C", "state": "present" } ] }
```

`PATCH /teaching/sections/{id}/attendance/{session}`:

```json
{ "marks": [ { "student": "U05079C", "state": "justified" } ] }
```

Suspended students are always recorded as `suspended`; the upstream date
format and `cod_cursal` are handled by the backend.

### VirtualClass, Punch, Compliance

```json
{ "id": "C123", "course": "…", "section": "A1", "career": "…", "start": "08:00", "end": "09:45", "tolerance": { "before_minutes": 10, "after_minutes": 15 }, "checked_in_at": null, "checked_out_at": null, "can_check_in": true, "can_check_out": false }
```

```json
{ "date": "2026-10-07", "time": "07:58", "weekday": 3, "mode": "Entrada", "location": "VIRTUAL", "virtual": true }
```

```json
{ "date": "2026-10-07", "weekday": 3, "course": "…", "section": "A1", "start": "08:00", "end": "09:45", "modality": "in_person", "check_in": "marked", "check_out": "missing" }
```

`check_in` / `check_out`: `marked | missing | pending | unknown`. Compliance
pages are walked and deduplicated on the server.

### Teacher profile, clock and report

`GET /teaching/me` (SIGMA `Login/GetDatosEntidad`):

```json
{ "code": "D001", "first_name": "Juan Carlos", "last_name": "Perez Rojas", "full_name": "Juan Carlos Perez Rojas", "faculty": "Ingenieria", "specialty": "Docente Ordinario", "photo_url": "https://…" }
```

`GET /teaching/server-time` (SIGMA `Docente/GetHora`): `{ "now":
"2026-11-05T09:05:07-05:00" }`, Lima wall time with SIGMA's offset and
fraction dropped. `meta.source` is `sigma`, or `server` when SIGMA does not
answer and the backend's own clock (Lima) is used.

`GET /teaching/sections/{id}/report?format=pdf|xlsx` (default `pdf`, SIGMA
`Docente/GetReporteAuxiliar`) is the only route that answers with a file
instead of the JSON envelope: `content-type` of the format,
`content-disposition: attachment; filename="Registro auxiliar <course>
<section>.<ext>"` (ASCII only), `cache-control: no-store`. `codSaltem`,
`plan`, `asignID` and `tipoCalif` (0 sent as 12) are resolved on the server
from the Nexo section id. Errors still use the JSON envelope.

## 5. Upstream distortions fixed by the backend

| # | Upstream behaviour | What the app does today | Backend |
| --- | --- | --- | --- |
| 1 | SIGMA answers an expired session with its HTML page and status 200; Intranet answers `302 → sesion` with an empty body | Reauthenticates; some cases end as "no data" | Reauthenticates server-side; never returns HTML or a false empty list |
| 2 | Course average rounded (11.6 → 12), ungraded units count as 0 | Recomputes when the detail is loaded | `grade.current` vs `grade.official` |
| 3 | Workshops graded on 0–100 | Uses the official 0–20 when out of range | Always 0–20 |
| 4 | Same endpoint returns 11 columns (2026-1+) or 50 (legacy) | Two models and parsers | One `TermGrades` shape |
| 5 | Closed flag `"True"` (SIGMA) vs `"1"` (Intranet) | Intranet rows never closed | `closed` correct for both |
| 6 | Intranet "approved credits" is really this term's enrolled credits | Overrides SIGMA's real approved credits | `approved` and `enrolled_this_term` separated |
| 7 | Curriculum columns: cycle and credits misread | Cycle shows credits; credits always 0 | Correct columns |
| 8 | SIGMA schedule teacher key is `docente`; labs typed as practice/other | Teacher empty; labs shown as theory | Teacher and `lab` kept |
| 9 | Periods: different labels and orders per source; period numbers other than 1 labelled II | Last Intranet row assumed active | One id format, SIGMA `activo` |
| 10 | Positional arrays, numbers and booleans as strings, trailing spaces, `"--"`, `" "`, `No hay datos` rows | Parsed per screen; one schedule bug | Typed values, `null`, `[]` |
| 11 | Three date formats (`dd-MM-yyyy`, `dd/MM/yyyy`, `Mar 31 2026 05:34:33:537PM`) | Parsed per model | ISO 8601 |
| 12 | Payment history splits one operation into rows | Shown as separate rows | Grouped operations |
| 13 | `consultartotalPensiones` returns overdue rows, not a total | `totalPensiones` always 0 | Treated as the overdue list |
| 14 | Home "to pay" omits overdue debt | Partial total | `summary.pending_total` + `overdue_total` |
| 15 | Teacher sections arrive twice with different ids; schedule is free text with ids by day index | Fuzzy merge in the app | One section, one id |
| 16 | Grade columns have no id; insert has no column field | Array position | `column` handled server-side |
| 17 | `tipoCalif` may be 0 (means 12); attendance time unpadded; server time offset must be ignored | Workarounds in the app | Hidden behind the API |
| 18 | Idiomas: different host for login and data, `contraseña` key, `"Correcto"` success flag, `0` = no grade | Special repository | Normal `/languages` |

## 6. Not yet confirmed against real responses

These fields are in the contract, but no saved upstream sample proves their
source. They must be checked with a real account before the module ships:

- `GET /teaching/me`, `GET /teaching/sections/{id}/report`: no raw SIGMA
  sample of `Login/GetDatosEntidad` or `Docente/GetReporteAuxiliar`; keys and
  query come from the app. It is assumed that the report answers with the
  bytes directly and a failure as JSON or the web page.
- `GET /grades` → `type`: only `TN` (mandatory) is seen in samples; `TE`,
  `TA`, `TT`, `TP` → `elective`, `activity`, `workshop`, `practicum` are
  assumed. A `0` evidence in an in-progress course is read as "not graded
  yet".
- `GET /grades/summary` → `terms`: SIGMA `ListarPromediosResumen` had no
  saved sample; keys come from the app's parser. (`current_term` counts now
  come from the term's own grades, not from `MostrarConteoNotas`.)
- `GET /wifi`: SIGMA `ObtenerWifiUsuario` key names are guesses (no sample);
  the backend accepts `usuario/user/usuarioWifi/username` and
  `contrasena/contraseña/clave/password/contrasenaWifi`.
- `GET /curriculum` → `attempts` (column 14 is "probably" attempts). Cycle
  (col 5) and credits (col 8) are confirmed by the saved sample.
- `GET /payments` → `kind: "discount"` from `consultarReduccionDeuda`: the
  only sample is empty.
- `GET /enrollment`: no raw sample saved; positions come from the page's own
  JavaScript and the app's parser (student cycle col 18, falling back to the
  course cycle col 9; total credits col 17).
- `VirtualClass.tolerance`: `tol_ini` / `tol_fin` are integers; their unit
  (minutes before/after) is assumed.
- Teacher module (module 5): no raw SIGMA `Docente/*` response is saved; the
  keys come from the official web client's bundle and the app's parsers.
  Assumed: SIGMA answers a rejected write with `success: false`;
  `InsertarNotas` appends the next column (so `PUT …/grades` refuses a
  column beyond the next free one, `column_gap`); the hidden attendance
  units are `212, 214, 215, 115, 116`. `PUT …/grades` also accepts a
  `column` per grade (default: the request's `column`, else the next free
  column). The auxiliary report (`Docente/GetReporteAuxiliar`, a file) has
  no Nexo route yet: the app still asks SIGMA, finding the section by NRC
  and section.
- SIGMA student endpoints (`MostrarInfoEstudiante`, schedule, grades) returned
  the HTML page in the saved samples, so their JSON keys come from the app's
  parsers and `API.md`, not from a captured response.

## 7. Legal

`Nexo.Legal` is the single source of truth: version, date, a summary of
what changed and the texts (`priv/legal/*.md`, also bundled in the app).
Bump its version when a document changes and the app asks everyone to accept
again, without an app update.

`GET /legal` (public, no attestation):

```json
{ "version": 5, "updated_at": "2026-11-14",
  "summary": ["La app ahora se comunica solo con la API de Nexo…", "…"],
  "documents": [
    { "id": "terms", "title": "Términos y Condiciones", "url": "https://api.nexo.aurx.pro/terminos" },
    { "id": "privacy", "title": "Política de Privacidad", "url": "https://api.nexo.aurx.pro/privacidad" },
    { "id": "cookies", "title": "Política de Cookies", "url": "https://api.nexo.aurx.pro/cookies" } ] }
```

`POST /me/legal/accept` `{ "version": 5 }` (student, teacher or guardian)
→ `{ "version": 5, "accepted_at": "…", "current": true }`. Every acceptance
is a new row in `legal_acceptances` (subject, version, timestamp, IP, user
agent) plus a `legal_accepted` audit entry; versions above the current one
are `422 unknown_version`. HTML pages: `/terminos`, `/privacidad` (and
`/privacy`), `/cookies`. `/terms` stays the students' term list.
