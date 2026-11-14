defmodule Nexo.IntranetMock do
  @moduledoc """
  Intranet stand-in for tests. Positional rows with the real shapes, values
  made up.

    * `"E001"`/`"ok"` and `"down"`/`"ok"` log in (`"down"` is the account
      whose SIGMA is down, to test the Intranet-only login);
    * cookies `"PHPSESSID=expired"` behave like an expired session.
  """
  @behaviour Nexo.Upstream.Intranet

  @legacy_keys ~w(nombreFacultad nombreCarrera planEstudios codigo asignatura plan ciclo
    seccion credito asistencia pF1 pF2 pf complementario pfp cc cicloTotal seccionTotal
    creditosTotal mtr_Anio mtr_Periodo tipoAsignatura tar_Id puesto p1 p2 p3 p4 p5 p6 p7 p8
    ntaP1 ntaTI1 ntaPY1 ntaPromTiPy ntaParcial1 _2P1 _2P2 _2P3 _2P4 _2P5 _2P6 _2P7 _2P8
    _2NtaP1 _2NtaTI1 _2NtaPY1 _2NtaPromTiPy _2NtaParcial1)

  @impl true
  def login(user, "ok") when user in ["E001", "E004", "down"], do: {:ok, "PHPSESSID=#{user}"}
  def login("offline", _), do: {:error, :unavailable}
  def login(_, _), do: {:error, :invalid_credentials}

  @impl true
  def post("PHPSESSID=expired", _path, _form, _referer), do: {:error, :session_expired}

  def post(cookies, "consultarPeriodosMatriculados", _form, _referer) do
    {:ok, [["2025", "2"], ["2026", "1"], ["2026", "2"]], cookies}
  end

  def post(cookies, "consultarConstanciaMatriculaEstudiante", %{"periodo" => "2026-2"}, _) do
    header = fn course, name, credits ->
      [
        "E001",
        "ROJAS QUISPE JOSE",
        "INGENIERÍA",
        "IS",
        "INGENIERÍA DE SISTEMAS Y COMPUTACIÓN",
        "-------",
        course,
        name,
        "2015",
        "07",
        "A1",
        "2026",
        "2",
        credits,
        "PRESENCIAL",
        "",
        "",
        "22",
        "07",
        "https://academico.upla.edu.pe/x.jpg",
        "A1",
        "Carrera"
      ]
    end

    {:ok, [header.("IS-301", "BASE DE DATOS", "3"), header.("IS-302", "REDES", "4")], cookies}
  end

  # E004's matrix is empty, so its schedule comes from SIGMA.
  def post(
        "PHPSESSID=E004" = cookies,
        "verhorariomatriz-matriculados3EstudianteEstudiante",
        _,
        _
      ),
      do: {:ok, [], cookies}

  # Rows are time slots; columns 3–9 are Monday–Sunday. A cell packs 14
  # `_`-separated fields; shared cells hold comma lists, and field 6 is a
  # colour with commas of its own. The Monday session repeats in the second
  # slot, as the real matrix does for long classes.
  def post(cookies, "verhorariomatriz-matriculados3EstudianteEstudiante", _, _) do
    monday =
      "101_IS-301_BASE DE DATOS_35/40_x_1_rgba(10, 20, 30, 0.5)_2015_08:00_09:45_A1_HUANCAYO_" <>
        "PABELLON H - H 302 - AFORO: 40_Teoría"

    wednesday =
      "102_IS-301_BASE DE DATOS_35/40_x_2_rgba(10, 20, 30, 0.5)_2015_10:00_11:30_A1_HUANCAYO_" <>
        "PABELLON H - H 305_Práctica"

    thursday =
      "103,104_IS-302,IS-303_REDES,ETICA_30/40,20/30_x,x_1,1_rgba(1, 2, 3, 0.4)_2015,2015_" <>
        "14:00,14:00_15:30,15:30_A1,B1_HUANCAYO,HUANCAYO_PABELLON K - K 101,PABELLON K - K 102_" <>
        "Teoría,Teoría"

    {:ok,
     [
       ["08:00", "09:45", "1", monday, "", "", "", "", "", ""],
       ["09:45", "11:30", "2", monday, "", wednesday, thursday, "", "", ""]
     ], cookies}
  end

  def post(cookies, "verhorarioseleccion-detalleEstudiante", _, _) do
    {:ok,
     [
       ["BASE DE DATOS", "", "", "", "", "", "", "", "", "GARCIA LOPEZ ANA", "LAB_SISTEMAS 2"],
       ["REDES", "", "", "", "", "", "", "", "", "PEREZ ROJAS JUAN"]
     ], cookies}
  end

  # Competencies model (2026 on): 11 columns. An in-progress course's average
  # column holds the points so far (14.5 on a 20 % unit → 2.9); a workshop is
  # graded on 0–100.
  def post(cookies, "consultarconstanciaNotasDetallado", %{"anio" => "2026"}, _) do
    {:ok,
     [
       ["G-1", "2015", "07", "3", "IS-301", "BASE DE DATOS", "A1", "95", "2.9000", "3", "Dsp."],
       [
         "G-2",
         "2015",
         "07",
         "1",
         "IS-TAL",
         "TALLER DE ARTE",
         "A1",
         "100",
         "85.0000",
         "17",
         "Apr."
       ],
       ["G-3", "2015", "07", "4", "IS-302", "REDES", "A1", "70", "9.4000", "9", "Des."]
     ], cookies}
  end

  # E004 has no legacy rows in the Intranet, so they come from SIGMA.
  def post("PHPSESSID=E004" = cookies, "consultarconstanciaNotasDetallado", _, _),
    do: {:ok, [], cookies}

  # Legacy model (before 2026): 50 columns.
  def post(cookies, "consultarconstanciaNotasDetallado", %{"anio" => "2025"}, _) do
    values = %{
      "codigo" => "IS-201",
      "asignatura" => "ESTRUCTURA DE DATOS",
      "ciclo" => "05",
      "seccion" => "A1",
      "credito" => "4.000",
      "asistencia" => "90",
      "pF1" => "14",
      "pF2" => "16",
      "pf" => "15",
      "complementario" => "--   ",
      "pfp" => "15",
      "cc" => "1",
      "tipoAsignatura" => "TN",
      "puesto" => "3/40",
      "p1" => "15   ",
      "p2" => "13",
      "ntaP1" => "14",
      "ntaTI1" => "16   ",
      "ntaParcial1" => "13",
      "_2P1" => "16",
      "_2NtaParcial1" => "16"
    }

    {:ok, [Enum.map(@legacy_keys, &Map.get(values, &1, "     "))], cookies}
  end

  # Unit 1 (20 %) graded, unit 2 (30 %) with zeros = not graded yet, unit 3
  # (50 %) empty. Tables 2 and 4 repeat data and must be ignored.
  def post(cookies, "consultarDetalleBoletaNotas", %{"matricula_asignatura_id" => "G-1"}, _) do
    row = fn unit, weight, type, ev_weight, grade, tbl ->
      [" ", "G-1", "12", "121", unit, weight, "11", type, ev_weight, grade, " ", tbl]
    end

    {:ok,
     [
       row.("UNIDAD 1", "20.00", "EVIDENCIA DE CONOCIMIENTO", "40.00", "14.00", "tbl1"),
       row.("UNIDAD 1", "20.00", "EVIDENCIA DE DESEMPEÑO", "60.00", "15.00", "tbl1"),
       row.("UNIDAD 1", "20.00", "EVIDENCIA DE CONOCIMIENTO", "40.00", "14.00", "tbl2"),
       row.("UNIDAD 2", "30.00", "EVIDENCIA DE PRODUCTO", "100.00", "0.00", "tbl1"),
       row.("UNIDAD 3", "50.00", "EVIDENCIA DE PRODUCTO", "100.00", " ", "tbl1"),
       row.("UNIDAD 1", "20.00", " ", " ", "15.00", "tbl3"),
       row.("UNIDAD 2", "30.00", " ", " ", "0.00", "tbl3"),
       [" ", "G-1", " ", " ", " ", " ", " ", " ", " ", "14.00", " ", "tbl4"],
       [" ", "G-1", " ", " ", "SUSTITUTORIO", " ", " ", " ", " ", " ", " ", "tbl5"],
       [" ", "G-1", " ", " ", " ", " ", " ", " ", " ", "3.00", "Dsp.", "tbl6"]
     ], cookies}
  end

  # Curriculum: col 3 state, 4 type, 5 cycle, 6 code, 7 name, 8 credits,
  # 12 grade, 14 attempts.
  def post(cookies, "consultarProgresoCurricular", %{"codest" => "E001"}, _) do
    row = fn state, type, cycle, code, name, credits, grade, attempts ->
      ["INGENIERÍA", "INGENIERÍA DE SISTEMAS Y COMPUTACIÓN", "2015", state, type, cycle, code] ++
        [name, credits, "0", code, " ", grade, " ", attempts, "Jul 13 2025", "ROJAS QUISPE JOSE"]
    end

    {:ok,
     [
       row.("pendiente", "TE", "9", "IS-901", "TESIS I", "4", " ", "0"),
       row.("concluido", "TN", "1", "IS-101", "INTRODUCCION A LA INGENIERIA", "3", "15", "1")
     ], cookies}
  end

  # Debt page, rows as captured from a real account (2026-1).
  def post(cookies, "consultarPensiones", %{"codEst" => "E001"}, _) do
    {:ok,
     [
       ["CUOTA 03 Periodo 2026-1", "12-06-2026", "S/.", "522.5", "0", "522.5", "--"],
       [
         "CUOTA 03 Periodo 2026-1",
         "13-06-2026",
         "S/.",
         "124",
         "0",
         "124",
         "AMP. CRED. 4 cred, 31.00 S/ cada cred PROV. No."
       ]
     ], cookies}
  end

  # Not a total: the overdue installments.
  def post(cookies, "consultartotalPensiones", %{"codEst" => "E001"}, _) do
    {:ok,
     [
       [
         "CUOTA 02 Periodo 2026-1",
         "21-05-2026",
         "S/.",
         "124",
         "0.22",
         "124.22",
         "AMP. CRED. 4 cred, 31.00 S/ cada cred PROV. No."
       ]
     ], cookies}
  end

  def post(cookies, "consultarMatricula", _, _), do: {:ok, [["--", "--"]], cookies}

  def post(cookies, "consultarTasas", %{"codEst" => "E001"}, _) do
    {:ok, [["SEGURO UNIVERSITARIO POLICLINICO UPLA 261", "S/.", "20", "--"]], cookies}
  end

  # One bank operation arrives as one row per item.
  def post(cookies, "consultarUltimasOperaciones", %{"codEst" => "E001"}, _) do
    op = fn number, item, date, concept, amount, voucher ->
      ["0002", number, "PAGOS", item, date, "2026-1", concept, "S/.", amount] ++
        ["CMAC AG. 000076 OP. 569674", voucher, "CAJA HYO"]
    end

    {:ok,
     [
       op.("002368017", "01", "20/05/2026", "Cuota 02 PENSIONES DE ENSEÑANZA", "550", "B010-1"),
       op.("002368017", "02", "20/05/2026", "Cuota 02 DSCTO EXTRAORD.PP 5%", "-27.5", "B010-1"),
       op.(
         "002368016",
         "02",
         "20/05/2026",
         "Cuota 01 MORAS Y RECARGO HYO - SEDES",
         "0.29",
         "BB10-2"
       ),
       op.("002368016", "01", "20/05/2026", "Cuota 01 PENSIONES DE ENSEÑANZA", "124", "B012-3"),
       op.("002364467", "01", "27/04/2026", "Cuota 01 PENSIONES DE ENSEÑANZA", "550", "B010-4")
     ], cookies}
  end

  def post(cookies, _path, _form, _referer), do: {:ok, [["No hay datos"]], cookies}

  @impl true
  def get("PHPSESSID=expired", _path, _referer), do: {:error, :session_expired}

  def get(cookies, "datosEstudianteMatriculado", _referer) do
    {:ok, [[" ", " ", "IS", "SX", "2015", "01", "HU"]], cookies}
  end

  def get(cookies, "consultarCuotasEstudiante?installments=30", _referer) do
    row = fn n, due -> ["1", "2750", "550", n, due, "5", "Mar 31 2026 05:34:33:537PM"] end

    {:ok, [row.("02", "20/05/2026"), row.("01", "28/04/2026")], cookies}
  end

  def get(cookies, _path, _referer), do: {:ok, [], cookies}
end
