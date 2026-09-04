-- ===========================================================================
-- V239 — Planeador educativo: pantalla "Planilla de calificacion"
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- La pantalla es una MATRIZ estudiante x actividad para un
-- (grado -> grupo -> asignatura), con dos vistas del mismo dato ("Ver por:
-- Actividad" = columnas planas; "Ver por: Unidad" = las mismas columnas
-- agrupadas bajo un sub-header por unidad), una columna "DEFINIT PROY."
-- (definitiva proyectada del estudiante) y, por celda, un icono de
-- calificado / no aplica.
--
-- QUE YA EXISTIA Y NO SE DUPLICA AQUI:
--   * V226 fn_actividad_instrumento_obtener — estructura del instrumento de
--     una actividad (criterios/niveles de rubrica, items de cotejo, config de
--     escala). Es EXACTAMENTE lo que necesitan los popovers de calificacion
--     individual ("Valor (1-5)", "Items: [ ] ...") y el selector
--     "Diseño"/"Modalidad" del modo bulk. No hace falta nada nuevo.
--   * V227 fn_actividad_nota_calificar* / _bulk — la escritura de la celda
--     (individual) y del header de columna (bulk).
--   * V227 fn_actividad_nota_obtener — detalle de captura de UN estudiante
--     en UNA actividad (lo que el popover precarga al abrirse).
--   * V227 fn_actividad_estudiantes_calificaciones_listar — la tabla de la
--     pantalla "Calificaciones: <actividad>" (UNA sola actividad, con
--     asistencia del dia). NO sirve para esta pantalla: aqui el eje son N
--     actividades a la vez y no se pinta asistencia.
--   * V223 fn_unidad_calculo_definitiva_modo / TACTIVIDAD.PONDERACION —
--     el metodo de calculo de la unidad y el peso de cada actividad dentro
--     de ella. Se REUTILIZAN tal cual en la definitiva proyectada.
--
-- QUE FALTABA Y SE CONSTRUYE AQUI:
--   (1) fn_planilla_grupo_asignatura_assert — validacion unica de los
--       parametros del filtro en cascada Grado -> Grupo -> Asignatura.
--   (2) fn_planilla_actividades_universo — definicion UNICA de "cuales son
--       las columnas de la planilla", con su orden estable. La usan las dos
--       funciones publicas, para que el header y las celdas no puedan
--       desalinearse nunca.
--   (3) fn_asignatura_plan_vigente / fn_asignatura_plan_elemento_calculo /
--       fn_asignatura_plan_calculo_definitiva_modo — la configuracion del
--       motor de calculo de la definitiva (TASIGNATURA_PLAN), resuelta a
--       modos canonicos, y fn_planilla_definitiva_proyectada, la columna
--       "DEFINIT PROY." que la aplica.
--   (4) fn_planilla_columnas_listar — el HEADER (una fila por actividad, con
--       su unidad resuelta).
--   (5) fn_planilla_calificaciones_listar — el CUERPO (una fila por
--       estudiante, con sus celdas como JSONB + la definitiva proyectada).
--
-- -------------------------------------------------------------------------
-- DECISION 1 — ¿una funcion con p_agrupar_por, o dos?
--
-- Ni una ni dos "por vista": se parte en HEADER (columnas) + CUERPO (filas),
-- y el toggle "Ver por: Actividad | Unidad" NO cambia ninguna consulta.
-- Motivo: las dos vistas muestran EL MISMO conjunto de actividades; lo unico
-- que cambia es que la de "Unidad" pinta un sub-header agrupando columnas
-- consecutivas. Como fn_planilla_columnas_listar ya devuelve cada actividad
-- con su fk_tunidad/unidad y un orden que agrupa las actividades de una
-- misma unidad de forma contigua (ver DECISION 2), el cliente arma el
-- sub-header con un simple group-by sobre lo que ya recibio. Un parametro
-- p_agrupar_por habria producido dos formas de salida distintas para el
-- mismo dato — mas superficie de error, cero informacion adicional.
--
-- El cuerpo va aparte del header porque el header es UNA lista corta
-- (actividades) y el cuerpo es la lista larga y PAGINABLE (estudiantes):
-- repetir los metadatos de cada actividad dentro de cada fila de estudiante
-- seria O(estudiantes x actividades) de texto redundante. Las celdas si van
-- embebidas en la fila del estudiante (JSONB) porque ahi si son dato propio
-- de esa fila.
--
-- DECISION 2 — orden de las columnas: unidad (por NOMBRE, NULLS LAST -> las
-- actividades sueltas sin unidad quedan al final), luego FECHA_INICIO y
-- PK_TACTIVIDAD. Asi las actividades de una misma unidad SIEMPRE salen
-- contiguas, que es el requisito del sub-header "UNIDAD 1 | UNIDAD 2".
-- TUNIDAD no tiene columna de orden explicito (V22), por eso el criterio es
-- el nombre. fn_planilla_actividades_universo materializa ese orden en
-- orden_columna (row_number) para que header y celdas usen el MISMO indice.
--
-- DECISION 3 — universo de columnas: actividades ACTIVE de la asignatura
-- cuyo FK_TGRUPO es el grupo pedido, MAS las actividades sin grupo
-- (FK_TGRUPO NULL, permitido por V22) que tengan al menos un estudiante
-- asignado (TACTIVIDAD_ESTUDIANTE ACTIVE) matriculado en ese grupo. Una
-- actividad sin grupo no "pertenece" a ninguna planilla por si sola; lo que
-- la trae a esta es que le asignaron estudiantes de este grupo.
--
-- DECISION 4 — estado de cada celda (el icono ✅ / 🚫 de la pantalla). Se
-- distinguen los TRES casos de forma explicita, no por ausencia de dato:
--     'NO_ASIGNADA'    — el estudiante NO tiene TACTIVIDAD_ESTUDIANTE ACTIVA
--                        para esa actividad: esa actividad no le corresponde
--                        (el icono de prohibido). Es el caso de SANTIAGO
--                        JOSE GOMEZ LOPEZ en "Taller de Fracciones".
--     'NO_CALIFICABLE' — si esta asignado, pero su TACTIVIDAD_NOTA tiene
--                        CALIFICABLE='N' (excluido de la evaluacion sin
--                        desasignarlo).
--     'SIN_CALIFICAR'  — asignado y calificable, pero todavia sin nota.
--     'CALIFICADA'     — asignado y con nota.
-- Se devuelve ademas pkTactividadEstudiante en la celda: es justo el
-- parametro que necesitan fn_actividad_nota_obtener (precargar el popover) y
-- fn_actividad_nota_calificar* (guardarlo) — la pantalla no requiere una
-- consulta extra para saber a quien calificar. En 'NO_ASIGNADA' viene NULL,
-- lo que hace imposible por construccion abrir el popover de una celda que
-- no aplica.
--
-- -------------------------------------------------------------------------
-- DEFINITIVA PROYECTADA — REGLA DEL MOTOR LEGACY (confirmada), con UNA
-- excepcion documentada.
--
-- La primera version de esta migracion calculaba SIEMPRE por-unidad y luego
-- promedio simple entre unidades, y lo documentaba como "hipotesis debil sin
-- ninguna pista en el repo". Eso YA NO APLICA: se investigo el motor de
-- calculo LEGACY (en produccion, fuera de esta rama) contra el servidor real
-- (172.233.184.248, 2026-09-03) y SI existe una regla, configurada por
-- asignatura+plan de estudios en TASIGNATURA_PLAN (V22), con DOS campos:
--
--   * TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF (TLISTA_VALOR, categoria
--     ELEMENTO_CALCULO_DEF) = QUE se combina para dar la definitiva. En el
--     servidor real SOLO existen dos valores, y nunca existio uno "Unidades":
--         VALOR='2' "Actividades"  — 8023 filas activas (el caso normal)
--         VALOR='1' "Instrumentos" — 1668 filas
--     Reinterpretacion CONFIRMADA con negocio para el Planeador:
--     "Instrumentos" es el nombre que el motor legacy le da a lo que aqui se
--     llama UNIDAD. Por eso el modo canonico que devuelve el helper es
--     'ACTIVIDADES' | 'UNIDADES' (y no 'INSTRUMENTOS'): se nombra el concepto
--     del Planeador, no la etiqueta heredada.
--   * TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA (TLISTA_VALOR, categoria
--     CALCULO_DEFINITIVA) = COMO se combinan esos elementos. Es EL MISMO
--     catalogo que TUNIDAD.FK_TLV_CALCULO_DEFINITIVA de V73, con los MISMOS
--     VALOR ya confirmados en V223 ('1' Promediar, '2' Ponderar, '3'
--     Sumatoria) — por eso el helper de resolucion es un calco exacto de
--     fn_unidad_calculo_definitiva_modo, solo que leyendo la otra tabla.
--
-- Formula final:
--
--   a) UNIVERSO (igual que antes). Solo cuentan las actividades
--      ES_EVALUATIVA='S' de la asignatura a las que el estudiante esta
--      asignado y que YA tienen nota (COALESCE(DEFINITIVA, CALIFICACION) IS
--      NOT NULL) y son calificables (CALIFICABLE <> 'N'). Por eso es
--      "PROYECTADA": es la definitiva que lleva HOY, no la del cierre. Se usa
--      COALESCE(DEFINITIVA, CALIFICACION) para que la recuperacion
--      consolidada (V224) mande sobre la nota original.
--
--   b) ELEMENTO_CALCULO_DEF = 'Actividades' (VALOR='2') -> calculo PLANO: se
--      combinan DIRECTAMENTE todas las actividades evaluativas del estudiante
--      en la asignatura, SIN pasar por unidad, con el modo de
--      TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA:
--        * PONDERAR / SUMATORIA -> SUM(nota*PONDERACION)/SUM(PONDERACION)
--          sobre las YA calificadas (renormalizado: es una proyeccion, no un
--          castigo por lo pendiente). En SUMATORIA la PONDERACION ya es
--          derivada de NOTA_MAXIMA (V223), asi que la misma formula sirve.
--        * PROMEDIAR, sin modo elegido, o suma de pesos 0 -> promedio SIMPLE.
--      Ojo: PONDERACION esta validada al 100% POR (unidad, grupo) (V223), no
--      por asignatura; al aplanar, las actividades de N unidades compiten en
--      un mismo denominador. Es exactamente lo que hace el motor legacy en
--      este modo — la renormalizacion por SUM(peso) lo deja consistente.
--
--   c) ELEMENTO_CALCULO_DEF = 'Instrumentos' (VALOR='1') -> calculo POR
--      UNIDAD: cada unidad resuelve su nota con el metodo de V223
--      (fn_unidad_calculo_definitiva_modo, mismas reglas del punto (b) pero
--      acotadas a la unidad), y esas notas-de-unidad se combinan entre si con
--      TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA.
--
--      *** UNICA EXCEPCION DOCUMENTADA — ponderacion entre unidades. *** Si
--      ese modo resulta PONDERAR o SUMATORIA, NO HAY CON QUE PONDERAR: no
--      existe en el esquema ninguna columna de peso de una UNIDAD dentro de
--      la asignatura (TACTIVIDAD.PONDERACION de V223 pesa una ACTIVIDAD
--      DENTRO de su unidad, y TUNIDAD no tiene peso propio). Inventar un peso
--      (p.ej. reusar la suma de PONDERACION de la unidad, o el numero de
--      actividades) seria fabricar negocio. Se cae a PROMEDIO SIMPLE entre
--      unidades y se deja constancia aqui. Es el unico punto de la formula
--      que no reproduce fielmente al motor legacy.
--
--   d) Actividades SIN unidad (FK_TUNIDAD NULL, posible desde V218): en el
--      modo por unidad forman UN bucket propio con promedio simple (no tienen
--      metodo de calculo que consultar). En el modo plano no son un caso
--      especial: entran como cualquier otra actividad.
--
--   e) SIN configuracion (no se pudo resolver la fila de TASIGNATURA_PLAN, o
--      FK_TLV_ELEMENTO_CALCULO_DEF es NULL) -> fallback: por unidad y luego
--      promedio simple entre unidades, es decir el mismo camino del punto (c)
--      con modo inter-unidad no resuelto. Es el comportamiento por defecto
--      razonable (respeta el metodo que el docente SI configuro en cada
--      unidad) y se documenta como tal.
--
--   f) Resultado en PORCENTAJE 0-100, igual que TACTIVIDAD_NOTA.CALIFICACION
--      (regla de V227): sin homologar a la escala visual del periodo — misma
--      frontera que ya documenta V227.
--   g) NO PERSISTE NADA. fn_planilla_definitiva_proyectada sigue siendo
--      STABLE y no escribe en TUNIDAD_NOTA. Consolidar la nota de unidad es
--      un flujo de cierre de periodo, no un efecto colateral de una lectura.
--
-- -------------------------------------------------------------------------
-- RESOLUCION DEL TASIGNATURA_PLAN DEL ESTUDIANTE — LIMITACION CONOCIDA.
--
-- TASIGNATURA_PLAN es unico por (FK_TASIGNATURA, FK_TPLAN) y TPLAN cuelga de
-- FK_TGRADO (V22/V44). NO hay FK de TMATRICULA ni de TGRUPO a TPLAN, asi que
-- el unico camino es matricula -> grupo -> grado -> plan(es) del grado.
--
-- Se busco un helper ya existente antes de escribir uno (V44 modulo de plan
-- de estudio, V45 horarios, V46 asignacion academica, V81, V186): NO EXISTE
-- ninguna funcion "plan vigente de una matricula/grupo". Lo que SI existe es
-- una CONVENCION uniforme en todo el repo: se asume UN solo TPLAN ACTIVE por
-- grado. V44 fn_plan_* hace literalmente
-- "SELECT PK_TPLAN INTO v_plan_id FROM TPLAN WHERE FK_TGRADO = ... AND
-- ACTIVE = TRUE" (sin desempate, y crea el plan si no existe), y V45/V46/V186
-- joinean "TPLAN ON FK_TGRADO = ... AND ACTIVE = TRUE" sin acotar a uno.
--
-- Pero en el servidor real hay 59 grados con MAS DE UN TPLAN activo, o sea
-- que esa convencion no siempre se cumple y esos joins ya son ambiguos hoy.
-- Aqui NO se inventa una regla de vigencia que el esquema no soporta (TPLAN
-- no tiene fecha de vigencia ni marca de "principal"): se toma el plan activo
-- MAS RECIENTE del grado (CREATED_AT DESC, PK_TPLAN DESC como desempate
-- determinista) y se documenta como limitacion. En el caso mayoritario (un
-- solo plan activo) es exacto; en un grado multi-plan puede elegir el plan
-- equivocado y, con ello, aplicar el elemento/modo de calculo equivocado. El
-- impacto esta acotado: si no se resuelve ninguna fila se cae al fallback (e),
-- que es el comportamiento que esta migracion ya tenia.
--
-- Cuando el negocio defina como se vincula una matricula a su plan (columna
-- en TMATRICULA/TGRUPO, o vigencia en TPLAN), el cambio es de UNA funcion:
-- fn_asignatura_plan_vigente.
--
-- TODO EXPLICITO — la FLECHA verde/roja de "DEFINIT PROY." (sube/baja) NO se
-- implementa. Requiere una linea base contra la cual comparar (la definitiva
-- del corte anterior). La unica candidata del esquema es
-- TUNIDAD_NOTA.DEFINITIVA y, como se explico, nadie la escribe todavia: la
-- comparacion daria siempre NULL. Se devuelve definitiva_registrada (lo que
-- haya consolidado en TUNIDAD_NOTA para las unidades de esa asignatura, hoy
-- siempre NULL) y tendencia ('SUBE'|'BAJA'|'IGUAL'|NULL) ya calculada, para
-- que la flecha empiece a funcionar sola en cuanto exista la consolidacion,
-- sin cambiar el contrato. Mientras tanto tendencia viene NULL y el cliente
-- no debe pintar flecha. Se prefiere esto a inventar una linea base.
--
-- -------------------------------------------------------------------------
-- FILTRO EN CASCADA — Grado -> Grupo -> Asignatura. La pantalla no muestra
-- nada hasta tener la seleccion ("Seleccione Grado, Grupo o Asignatura"),
-- asi que p_fk_tgrupo y p_fk_tasignatura son OBLIGATORIOS (22023 si faltan);
-- p_fk_tgrado es opcional y, si viene, se valida que sea el grado del grupo
-- (23503) — es el ultimo eslabon de la cascada y sirve para detectar un
-- filtro incoherente en el cliente en vez de devolver datos del grupo
-- equivocado en silencio. El rango de fechas y el buscador de actividad
-- acotan las COLUMNAS (misma semantica de solapamiento que
-- fn_actividad_listar de V224, deliberadamente identica); el buscador de
-- estudiante acota las FILAS.
--
-- NOTA: no se reutiliza fn_actividad_listar (V224) para armar las columnas.
-- No tiene filtro por grado, no contempla la regla de las actividades sin
-- grupo (DECISION 3), pagina por actividad (aqui la paginacion es por
-- estudiante) y trae progreso/estado que esta pantalla no pinta. Lo que si
-- se reutiliza es su semantica de ventana de fechas, replicada tal cual.
--
-- -------------------------------------------------------------------------
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD, TACTIVIDAD_ESTUDIANTE, TACTIVIDAD_NOTA, TUNIDAD,
--            TUNIDAD_NOTA, TMATRICULA, TGRUPO, TGRADO, TESTUDIANTE, TUSUARIO,
--            TPLAN, TASIGNATURA_PLAN (FK_TLV_ELEMENTO_CALCULO_DEF y
--            FK_TLV_CALCULO_DEFINITIVA: el motor de calculo de la definitiva).
--   * V29/V185 — fn_assert_permiso_seccion.
--   * V216 — menu 'PLANEADOR'.
--   * V223 — TACTIVIDAD.PONDERACION, fn_unidad_calculo_definitiva_modo.
--   * V224 — modulo de actividades (contexto).
--   * V218 (rama CU-86e329pvq, misma dependencia cross-branch que ya
--     declaran V223/V224) — TACTIVIDAD.FK_TASIGNATURA y FK_TUNIDAD nullable.
--   * V73 (rama CU-86e30a25v) — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, via
--     fn_unidad_calculo_definitiva_modo.
--
-- Estilo: V224/V227 (gate fn_assert_permiso_seccion, RAISE ... USING
-- ERRCODE, CTE base + COUNT(*) OVER() para el listado paginable, COMMENT ON
-- FUNCTION, DROP FUNCTION IF EXISTS antes de CREATE OR REPLACE).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) HELPERS
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_planilla_grupo_asignatura_assert — validacion UNICA del filtro en
-- cascada. Punto unico para que las dos funciones publicas den exactamente
-- el mismo error ante el mismo filtro invalido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planilla_grupo_asignatura_assert(
    p_fk_tgrupo       BIGINT,
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_grado_del_grupo BIGINT;
    v_nombre_grupo    VARCHAR;
BEGIN
    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'Debe seleccionar grupo y asignatura para consultar la planilla de calificacion'
            USING ERRCODE = '22023';
    END IF;

    SELECT g.FK_TGRADO, g.NOMBRE
      INTO v_grado_del_grupo, v_nombre_grupo
      FROM academico_test.TGRUPO g
     WHERE g.PK_TGRUPO = p_fk_tgrupo AND g.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA a
         WHERE a.PK_TASIGNATURA = p_fk_tasignatura AND a.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Ultimo eslabon de la cascada: si el cliente manda grado, debe ser el
    -- del grupo. Mensaje con el NOMBRE del grupo, no solo su PK.
    IF p_fk_tgrado IS NOT NULL AND p_fk_tgrado <> v_grado_del_grupo THEN
        RAISE EXCEPTION 'El grupo % no pertenece al grado seleccionado', v_nombre_grupo
            USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_grupo_asignatura_assert(BIGINT, BIGINT, BIGINT)
    IS 'Valida el filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion": exige grupo y asignatura (22023 si falta alguno, la pantalla no muestra nada hasta tenerlos), que ambos existan y esten ACTIVE (P0002) y, si se manda grado, que sea el grado de ese grupo (23503, con el NOMBRE del grupo en el mensaje). Punto UNICO de esa validacion, usado por fn_planilla_columnas_listar y fn_planilla_calificaciones_listar para que el mismo filtro invalido de siempre el mismo error. V239.';

-- ---------------------------------------------------------------------------
-- fn_planilla_actividades_universo — definicion UNICA de las COLUMNAS de la
-- planilla y de su orden (ver DECISION 2 y DECISION 3 en la cabecera).
--
-- La usan las DOS funciones publicas. Es lo que garantiza que el header y
-- las celdas no puedan desalinearse: orden_columna sale de aqui, no se
-- recalcula en cada sitio.
--
-- No gatea permisos: es un helper interno, siempre invocado desde una
-- funcion que ya valido VER sobre PLANEADOR (mismo criterio que
-- fn_unidad_ponderacion_recalcular_sumatoria de V223).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planilla_actividades_universo(
    p_fk_tgrupo        BIGINT,
    p_fk_tasignatura   BIGINT,
    p_fecha_desde      DATE    DEFAULT NULL,
    p_fecha_hasta      DATE    DEFAULT NULL,
    p_search_actividad VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    orden_columna   INT,
    pk_tactividad   BIGINT,
    fk_tunidad      BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT ROW_NUMBER() OVER (
               ORDER BY u.NOMBRE NULLS LAST,
                        a.FK_TUNIDAD NULLS LAST,
                        a.FECHA_INICIO NULLS LAST,
                        a.PK_TACTIVIDAD
           )::INT,
           a.PK_TACTIVIDAD,
           a.FK_TUNIDAD
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE a.ACTIVE = TRUE
       AND a.FK_TASIGNATURA = p_fk_tasignatura
       -- DECISION 3: las del grupo, mas las sin grupo que tengan al menos un
       -- estudiante de este grupo asignado.
       AND (a.FK_TGRUPO = p_fk_tgrupo
            OR (a.FK_TGRUPO IS NULL AND EXISTS (
                    SELECT 1
                      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
                     WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       AND ae.ACTIVE = TRUE
                       AND m.FK_TGRUPO = p_fk_tgrupo)))
       -- Ventana de fechas: misma semantica de solapamiento que
       -- fn_actividad_listar (V224), deliberadamente identica.
       AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
       AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
       AND (p_search_actividad IS NULL
            OR TRIM(p_search_actividad) = ''
            OR (COALESCE(a.TITULO, '') || ' ' || COALESCE(a.DESCRIPCION, ''))
                   ILIKE '%' || TRIM(p_search_actividad) || '%');
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_actividades_universo(BIGINT, BIGINT, DATE, DATE, VARCHAR)
    IS 'Definicion UNICA de las COLUMNAS de la pantalla "Planilla de calificacion" y de su orden: actividades ACTIVE de la asignatura cuyo FK_TGRUPO es el grupo pedido, MAS las actividades sin grupo (FK_TGRUPO NULL) que tengan al menos un TACTIVIDAD_ESTUDIANTE ACTIVO matriculado en ese grupo (una actividad sin grupo no pertenece a ninguna planilla por si sola; la trae aqui el haberle asignado estudiantes de este grupo). Filtra por ventana de fechas con la MISMA semantica de solapamiento de fn_actividad_listar (V224) y por texto sobre TITULO+DESCRIPCION. Devuelve orden_columna (ROW_NUMBER por NOMBRE de unidad NULLS LAST -> FECHA_INICIO -> PK, de modo que las actividades de una misma unidad salen SIEMPRE contiguas, requisito del sub-header "Ver por: Unidad"; TUNIDAD no tiene columna de orden en V22, por eso el criterio es el nombre), pk_tactividad y fk_tunidad. La usan fn_planilla_columnas_listar y fn_planilla_calificaciones_listar: es lo que impide que header y celdas se desalineen. No gatea permisos (helper interno). V239.';

-- ---------------------------------------------------------------------------
-- fn_asignatura_plan_vigente — resuelve la fila de TASIGNATURA_PLAN que
-- configura el calculo de la definitiva para un (grupo, asignatura).
--
-- Camino unico posible con el esquema actual: grupo -> grado -> TPLAN activo
-- del grado -> TASIGNATURA_PLAN activo de esa asignatura. Ver la seccion
-- "RESOLUCION DEL TASIGNATURA_PLAN DEL ESTUDIANTE" de la cabecera: no existe
-- ningun helper previo en el repo y el desempate entre varios planes activos
-- del mismo grado (59 casos reales en el servidor) es una LIMITACION
-- documentada, no una regla de negocio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_vigente(
    p_fk_tgrupo       BIGINT,
    p_fk_tasignatura  BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT ap.PK_TASIGNATURA_PLAN
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TPLAN pl
        ON pl.FK_TGRADO = gr.FK_TGRADO AND pl.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap
        ON ap.FK_TPLAN = pl.PK_TPLAN
       AND ap.FK_TASIGNATURA = p_fk_tasignatura
       AND ap.ACTIVE = TRUE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE
     -- Desempate determinista cuando el grado tiene varios planes activos.
     ORDER BY pl.CREATED_AT DESC, pl.PK_TPLAN DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_vigente(BIGINT, BIGINT)
    IS 'Resuelve la fila de TASIGNATURA_PLAN (V22) que configura el calculo de la definitiva de una asignatura para los estudiantes de un grupo: grupo -> grado -> TPLAN ACTIVE del grado -> TASIGNATURA_PLAN ACTIVE de esa asignatura. NULL si no hay ninguna. LIMITACION CONOCIDA: el esquema no vincula una matricula/grupo a un plan concreto (no hay FK, ni vigencia ni marca de "principal" en TPLAN) y todo el repo (V44 fn_plan_*, V45, V46, V186) asume UN solo TPLAN activo por grado, cosa que en el servidor real no siempre se cumple (59 grados con mas de uno). Se toma el plan activo MAS RECIENTE (CREATED_AT DESC, PK_TPLAN DESC como desempate determinista); en un grado multi-plan puede elegir el equivocado. Punto UNICO de esa resolucion: cuando el negocio defina el vinculo real, se cambia solo aqui. V239.';

-- ---------------------------------------------------------------------------
-- fn_asignatura_plan_elemento_calculo — QUE se combina para dar la definitiva
-- de la asignatura: 'ACTIVIDADES' (plano) | 'UNIDADES' (por unidad), o NULL.
--
-- TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF, TLISTA_VALOR categoria
-- ELEMENTO_CALCULO_DEF. Confirmado contra el servidor real: solo existen
-- VALOR='2' "Actividades" y VALOR='1' "Instrumentos", y "Instrumentos" es el
-- nombre legacy de lo que el Planeador llama UNIDAD (ver cabecera). Se
-- resuelve por VALOR, nunca por PK, como manda la convencion del repo, y se
-- devuelve el nombre del concepto del Planeador, no la etiqueta heredada.
--
-- No filtra por lv.ACTIVE, por el mismo motivo que
-- fn_unidad_calculo_definitiva_modo (V223): desactivar la fila del catalogo
-- no debe cambiar en silencio el calculo de una nota.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_elemento_calculo(
    p_pk_tasignatura_plan  BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE lv.VALOR
               WHEN '2' THEN 'ACTIVIDADES'
               WHEN '1' THEN 'UNIDADES'
               ELSE NULL
           END::VARCHAR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ap.FK_TLV_ELEMENTO_CALCULO_DEF
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk_tasignatura_plan;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_elemento_calculo(BIGINT)
    IS 'Elemento base con el que el motor calcula la definitiva de una asignatura, a partir de TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF (TLISTA_VALOR categoria ELEMENTO_CALCULO_DEF): ''ACTIVIDADES'' (VALOR=''2'', combina PLANO todas las actividades evaluativas sin pasar por unidad; es el caso mayoritario en el servidor real: 8023 filas) | ''UNIDADES'' (VALOR=''1'', etiquetado "Instrumentos" en el legacy -- confirmado con negocio que "Instrumentos" es el nombre heredado de lo que el Planeador llama UNIDAD; 1668 filas) | NULL si no hay fila, el campo es NULL o el valor no se reconoce (nunca existio un tercer valor). Se resuelve por VALOR, nunca por PK. No filtra por lv.ACTIVE (mismo criterio que fn_unidad_calculo_definitiva_modo, V223: desactivar el catalogo no debe cambiar en silencio una nota). V239.';

-- ---------------------------------------------------------------------------
-- fn_asignatura_plan_calculo_definitiva_modo — COMO se combinan esos
-- elementos: 'PONDERAR' | 'PROMEDIAR' | 'SUMATORIA' | NULL.
--
-- Calco exacto de fn_unidad_calculo_definitiva_modo (V223) sobre la otra
-- tabla: TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA apunta al MISMO catalogo
-- CALCULO_DEFINITIVA que TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (V73), con los
-- mismos VALOR '1'/'2'/'3' ya confirmados por SSH en V223. Se duplica el CASE
-- en vez de factorizarlo porque el punto de entrada es otro (una fila de
-- plan, no una unidad) y factorizarlo obligaria a un helper que recibiera un
-- pk_lista_valor suelto — mas indireccion que valor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_calculo_definitiva_modo(
    p_pk_tasignatura_plan  BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE lv.VALOR
               WHEN '2' THEN 'PONDERAR'
               WHEN '1' THEN 'PROMEDIAR'
               WHEN '3' THEN 'SUMATORIA'
               ELSE NULL
           END::VARCHAR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ap.FK_TLV_CALCULO_DEFINITIVA
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk_tasignatura_plan;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_calculo_definitiva_modo(BIGINT)
    IS 'Modo canonico con el que se combinan los elementos base para dar la definitiva de una asignatura, a partir de TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA: ''PONDERAR'' | ''PROMEDIAR'' | ''SUMATORIA'' | NULL. Es el MISMO catalogo CALCULO_DEFINITIVA que usa TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (V73) con los MISMOS VALOR (''1'' Promediar, ''2'' Ponderar, ''3'' Sumatoria, confirmados por SSH en V223), por eso este helper es un calco de fn_unidad_calculo_definitiva_modo sobre la otra tabla. Se resuelve por VALOR, nunca por PK. V239.';

-- ---------------------------------------------------------------------------
-- fn_planilla_definitiva_proyectada — columna "DEFINIT PROY.".
--
-- Implementa la regla del motor LEGACY (TASIGNATURA_PLAN: elemento base +
-- modo de combinacion). Ver la seccion "DEFINITIVA PROYECTADA" de la
-- cabecera para el detalle, y la seccion "RESOLUCION DEL TASIGNATURA_PLAN"
-- para las dos limitaciones documentadas (plan ambiguo en grados multi-plan;
-- ponderacion ENTRE unidades sin peso real -> promedio simple).
--
-- Deliberadamente NO recibe el rango de fechas ni el buscador de actividad:
-- la definitiva de un estudiante en una asignatura no puede cambiar porque
-- el docente filtre la vista. Se calcula sobre TODAS sus actividades
-- evaluativas calificadas de esa asignatura.
--
-- No persiste nada (STABLE): consolidar TUNIDAD_NOTA es un flujo de cierre
-- de periodo, no un efecto colateral de una lectura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planilla_definitiva_proyectada(
    p_fk_tmatricula   BIGINT,
    p_fk_tasignatura  BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_asignatura_plan BIGINT;
    v_elemento           VARCHAR;   -- 'ACTIVIDADES' | 'UNIDADES' | NULL
    v_modo               VARCHAR;   -- 'PONDERAR' | 'PROMEDIAR' | 'SUMATORIA' | NULL
    v_resultado          NUMERIC;
BEGIN
    -- Configuracion del motor de calculo para (grupo de la matricula,
    -- asignatura). Puede no resolverse: en ese caso v_elemento queda NULL y
    -- se aplica el fallback (punto (e) de la cabecera).
    SELECT academico_test.fn_asignatura_plan_vigente(m.FK_TGRUPO, p_fk_tasignatura)
      INTO v_pk_asignatura_plan
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    IF v_pk_asignatura_plan IS NOT NULL THEN
        v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_asignatura_plan);
        v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_asignatura_plan);
    END IF;

    IF v_elemento = 'ACTIVIDADES' THEN
        -- (b) PLANO: todas las actividades evaluativas calificadas de la
        -- asignatura compiten en un mismo calculo, sin pasar por unidad.
        WITH notas AS (
            SELECT COALESCE(a.PONDERACION, 0)             AS peso,
                   COALESCE(n.DEFINITIVA, n.CALIFICACION) AS nota
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
               AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
               AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
        )
        SELECT ROUND(
                   CASE
                       WHEN v_modo IN ('PONDERAR', 'SUMATORIA') AND SUM(nt.peso) > 0
                       THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                       ELSE AVG(nt.nota)
                   END, 2)
          INTO v_resultado
          FROM notas nt;

        RETURN v_resultado;
    END IF;

    -- (c) POR UNIDAD (v_elemento = 'UNIDADES') y (e) fallback sin
    -- configuracion: comparten el mismo camino. Cada unidad calcula su nota
    -- con el metodo de V223 y las notas-de-unidad se combinan entre si.
    --
    -- EXCEPCION DOCUMENTADA: la combinacion ENTRE unidades es SIEMPRE
    -- promedio simple, incluso si v_modo dice PONDERAR/SUMATORIA. No existe
    -- peso de una unidad dentro de la asignatura en ningun lado del esquema
    -- (TACTIVIDAD.PONDERACION pesa la actividad DENTRO de su unidad), y
    -- fabricar uno seria inventar negocio. Ver la cabecera.
    WITH notas AS (
        SELECT a.FK_TUNIDAD,
               COALESCE(a.PONDERACION, 0)                  AS peso,
               COALESCE(n.DEFINITIVA, n.CALIFICACION)      AS nota
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.FK_TMATRICULA = p_fk_tmatricula
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
           AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
           AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
    ),
    por_unidad AS (
        SELECT CASE
                   WHEN academico_test.fn_unidad_calculo_definitiva_modo(nt.FK_TUNIDAD)
                            IN ('PONDERAR', 'SUMATORIA')
                        AND SUM(nt.peso) > 0
                   THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                   ELSE AVG(nt.nota)
               END AS nota_unidad
          FROM notas nt
         GROUP BY nt.FK_TUNIDAD
    )
    SELECT ROUND(AVG(pu.nota_unidad), 2)
      INTO v_resultado
      FROM por_unidad pu;

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_definitiva_proyectada(BIGINT, BIGINT)
    IS 'Columna "DEFINIT PROY." de la pantalla "Planilla de calificacion": definitiva PROYECTADA (porcentaje 0-100, sin homologar a la escala visual del periodo -- misma frontera que documenta V227) de un estudiante en una asignatura, con lo calificado HASTA HOY. Implementa la regla del motor de calculo LEGACY, confirmada contra el servidor real y con negocio: TASIGNATURA_PLAN (V22) define QUE se combina (FK_TLV_ELEMENTO_CALCULO_DEF -> fn_asignatura_plan_elemento_calculo) y COMO (FK_TLV_CALCULO_DEFINITIVA -> fn_asignatura_plan_calculo_definitiva_modo, mismo catalogo CALCULO_DEFINITIVA de V73/V223). Formula: (a) universo = actividades ES_EVALUATIVA=''S'' de la asignatura, asignadas al estudiante, con CALIFICABLE distinto de ''N'' y con nota COALESCE(TACTIVIDAD_NOTA.DEFINITIVA, CALIFICACION) no nula -- la DEFINITIVA manda para que la recuperacion consolidada (V224) pese sobre la nota original; (b) ELEMENTO=''ACTIVIDADES'' (VALOR=''2'', el caso mayoritario) -> calculo PLANO sobre TODAS esas actividades SIN pasar por unidad, con el modo del plan: PONDERAR/SUMATORIA -> SUM(nota*PONDERACION)/SUM(PONDERACION) renormalizado sobre las ya calificadas (por eso es proyeccion y no castigo por lo pendiente; en SUMATORIA la PONDERACION ya es derivada de NOTA_MAXIMA, V223), PROMEDIAR / sin modo / suma de pesos 0 -> promedio simple; (c) ELEMENTO=''UNIDADES'' (VALOR=''1'', etiquetado "Instrumentos" en el legacy: confirmado que es el nombre heredado de la UNIDAD del Planeador) -> cada unidad calcula su nota con fn_unidad_calculo_definitiva_modo (V223, misma mecanica del punto (b) acotada a la unidad; las actividades sin unidad forman un bucket propio con promedio simple) y esas notas-de-unidad se combinan entre si; (d) sin configuracion resoluble (no hay TASIGNATURA_PLAN o el elemento es NULL) -> fallback documentado: el mismo camino por unidad de (c). DOS LIMITACIONES DOCUMENTADAS: (1) la combinacion ENTRE unidades es SIEMPRE promedio simple aunque el plan diga PONDERAR/SUMATORIA, porque no existe en el esquema ningun peso de una UNIDAD dentro de la asignatura (TACTIVIDAD.PONDERACION pesa la actividad DENTRO de su unidad) e inventarlo seria fabricar negocio; (2) la fila de TASIGNATURA_PLAN se resuelve via fn_asignatura_plan_vigente (grupo -> grado -> plan activo mas reciente), que puede elegir mal en los grados con varios TPLAN activos. NULL si el estudiante no tiene ninguna actividad calificada. NO recibe el rango de fechas ni el buscador: la definitiva no puede cambiar porque el docente filtre la vista. NO persiste nada (STABLE): consolidar TUNIDAD_NOTA es un flujo de cierre de periodo, no un efecto colateral de una lectura. V239.';

-- ===========================================================================
-- (2) LECTURA — HEADER Y CUERPO DE LA PLANILLA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_planilla_columnas_listar — el HEADER de la planilla: una fila por
-- actividad-columna, con su unidad resuelta (para el sub-header de
-- "Ver por: Unidad"), su instrumento (para saber que popover abrir) y su
-- progreso de calificacion en ESTE grupo.
--
-- Sin paginacion: el universo ya esta acotado a un (grupo, asignatura) y,
-- normalmente, a un rango de fechas. Son las columnas de una tabla que un
-- humano tiene que poder leer en pantalla.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planilla_columnas_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    orden_columna                 INT,
    pk_tactividad                 BIGINT,
    titulo                        VARCHAR,
    fk_tunidad                    BIGINT,
    unidad                        VARCHAR,
    fk_tlv_instrumento_evaluacion BIGINT,
    instrumento                   VARCHAR,
    instrumento_nombre            VARCHAR,
    ponderacion                   NUMERIC,
    nota_maxima                   NUMERIC,
    es_evaluativa                 VARCHAR,
    fecha_inicio                  DATE,
    fecha_cierre                  DATE,
    estudiantes_asignados         BIGINT,
    estudiantes_calificados       BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    RETURN QUERY
    SELECT uni.orden_columna,
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.VALOR::VARCHAR,
           lvi.NOMBRE::VARCHAR,
           a.PONDERACION,
           a.NOTA_MAXIMA,
           a.ES_EVALUATIVA::VARCHAR,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           prog.asignados,
           prog.calificados
      FROM academico_test.fn_planilla_actividades_universo(
               p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
           ) uni
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
      LEFT JOIN academico_test.TUNIDAD u       ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      -- Progreso acotado a ESTE grupo: la actividad puede tener estudiantes
      -- de otros grupos y esta pantalla es la planilla de uno solo.
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE n.PK_TACTIVIDAD_NOTA IS NOT NULL
                       AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                 )::BIGINT AS calificados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
             AND m.FK_TGRUPO = p_fk_tgrupo
      ) prog ON TRUE
     ORDER BY uni.orden_columna;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_columnas_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR)
    IS 'HEADER de la pantalla "Planilla de calificacion": una fila por actividad-columna del (grupo, asignatura), en el MISMO orden_columna que devuelven las celdas de fn_planilla_calificaciones_listar (ambas salen de fn_planilla_actividades_universo, por eso no pueden desalinearse). Trae la unidad resuelta -- con eso el cliente arma el sub-header del toggle "Ver por: Unidad" con un group-by, sin otra consulta ni otro contrato: las actividades de una misma unidad vienen contiguas --, el instrumento (VALOR canonico + NOMBRE, para saber que popover de calificacion abrir y llamar despues a fn_actividad_instrumento_obtener de V226), PONDERACION/NOTA_MAXIMA, ES_EVALUATIVA, fechas y el progreso de calificacion acotado a ESE grupo (asignados / calificados; la actividad puede tener estudiantes de otros grupos). Filtros: ventana de fechas y buscador de actividad. Sin paginacion (son las columnas visibles de una tabla). Gate VER sobre PLANEADOR + fn_planilla_grupo_asignatura_assert. V239.';

-- ---------------------------------------------------------------------------
-- fn_planilla_calificaciones_listar — el CUERPO de la planilla: una fila por
-- estudiante del grupo, con TODAS sus celdas como JSONB y la definitiva
-- proyectada.
--
-- Las celdas van embebidas (no como N filas) porque son dato propio de la
-- fila del estudiante y porque el cliente pinta la matriz de una: devolver
-- estudiantes x actividades filas obligaria a pivotar en el cliente.
-- Los metadatos de cada actividad NO se repiten aqui (van en
-- fn_planilla_columnas_listar): la celda solo trae lo que cambia por
-- estudiante + la llave para cruzarla con su columna.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planilla_calificaciones_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_calificaciones_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_search_estudiante      VARCHAR DEFAULT NULL,
    p_limite                 INT     DEFAULT 50,
    p_offset                 INT     DEFAULT 0
)
RETURNS TABLE (
    pk_tmatricula           BIGINT,
    pk_testudiante          BIGINT,
    nombre_estudiante       VARCHAR,
    definitiva_proyectada   NUMERIC,
    definitiva_registrada   NUMERIC,
    tendencia               VARCHAR,
    celdas                  JSONB,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    RETURN QUERY
    WITH columnas AS MATERIALIZED (
        -- MATERIALIZED a proposito: este CTE se referencia UNA sola vez, y
        -- desde PG12 eso hace que el planner lo inline dentro del LATERAL de
        -- las celdas -- es decir, recalcularia el universo de columnas UNA VEZ
        -- POR ESTUDIANTE de la pagina. Materializarlo lo evalua una sola vez
        -- para toda la consulta.
        SELECT uni.orden_columna, uni.pk_tactividad, uni.fk_tunidad
          FROM academico_test.fn_planilla_actividades_universo(
                   p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
               ) uni
    ),
    base AS (
        -- Filtro + orden + paginacion tocando solo matricula/estudiante/usuario
        -- (leccion de V112/V224: los agregados caros van DESPUES, contra las
        -- <= p_limite filas de la pagina).
        SELECT m.PK_TMATRICULA,
               es.PK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               COUNT(*) OVER() AS total
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_search_estudiante IS NULL
                OR TRIM(p_search_estudiante) = ''
                OR TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%' || TRIM(p_search_estudiante) || '%')
         ORDER BY NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                             u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
                  m.PK_TMATRICULA
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT b.PK_TMATRICULA,
           b.PK_TESTUDIANTE,
           b.nombre,
           def.proyectada,
           reg.registrada,
           CASE
               WHEN def.proyectada IS NULL OR reg.registrada IS NULL THEN NULL
               WHEN def.proyectada > reg.registrada THEN 'SUBE'
               WHEN def.proyectada < reg.registrada THEN 'BAJA'
               ELSE 'IGUAL'
           END::VARCHAR,
           COALESCE(cel.celdas, '[]'::jsonb),
           b.total
      FROM base b
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_planilla_definitiva_proyectada(
                     b.PK_TMATRICULA, p_fk_tasignatura) AS proyectada
      ) def ON TRUE
      -- Linea base de la flecha verde/roja. Hoy siempre NULL: ninguna funcion
      -- del repo escribe TUNIDAD_NOTA (ver "TODO EXPLICITO" en la cabecera).
      -- Se deja calculado para que la flecha funcione sola en cuanto exista
      -- la consolidacion, sin cambiar el contrato.
      LEFT JOIN LATERAL (
          SELECT ROUND(AVG(COALESCE(un.DEFINITIVA, un.CALIFICACION)), 2) AS registrada
            FROM academico_test.TUNIDAD_NOTA un
            JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = un.FK_TUNIDAD
           WHERE un.FK_TMATRICULA = b.PK_TMATRICULA
             AND un.ACTIVE = TRUE
             AND tu.FK_TASIGNATURA = p_fk_tasignatura
      ) reg ON TRUE
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object(
                     'ordenColumna',            c.orden_columna,
                     'pkTactividad',            c.pk_tactividad,
                     'pkTunidad',               c.fk_tunidad,
                     -- Llave que necesitan fn_actividad_nota_obtener (precargar
                     -- el popover) y fn_actividad_nota_calificar* (guardar).
                     -- NULL cuando la celda no aplica: por construccion no se
                     -- puede abrir el popover de una actividad no asignada.
                     'pkTactividadEstudiante',  ae.PK_TACTIVIDAD_ESTUDIANTE,
                     'estado',
                         CASE
                             WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL          THEN 'NO_ASIGNADA'
                             WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'           THEN 'NO_CALIFICABLE'
                             WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NULL THEN 'SIN_CALIFICAR'
                             ELSE 'CALIFICADA'
                         END,
                     'calificacion',  n.CALIFICACION,
                     'recuperacion',  n.RECUPERACION,
                     'definitiva',    n.DEFINITIVA,
                     'nota',          COALESCE(n.DEFINITIVA, n.CALIFICACION),
                     'calificable',   n.CALIFICABLE,
                     'observacion',   n.OBSERVACION)
                     ORDER BY c.orden_columna) AS celdas
            FROM columnas c
            LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                   ON ae.FK_TACTIVIDAD = c.pk_tactividad
                  AND ae.FK_TMATRICULA = b.PK_TMATRICULA
                  AND ae.ACTIVE = TRUE
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
      ) cel ON TRUE
     ORDER BY b.nombre, b.PK_TMATRICULA;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_calificaciones_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT)
    IS 'CUERPO de la pantalla "Planilla de calificacion": una fila por estudiante ACTIVO matriculado en el grupo, con (a) su nombre completo, (b) definitiva_proyectada (fn_planilla_definitiva_proyectada -- regla del motor legacy configurada en TASIGNATURA_PLAN: plano por actividades o por unidad, ver la cabecera de V239 y sus dos limitaciones documentadas), (c) definitiva_registrada + tendencia (''SUBE''|''BAJA''|''IGUAL''|NULL) para la flecha verde/roja: la linea base sale de TUNIDAD_NOTA y HOY ES SIEMPRE NULL porque ninguna funcion del repo consolida esa tabla -- viene calculado para que la flecha funcione sola cuando exista la consolidacion, sin cambiar el contrato; mientras tendencia sea NULL el cliente no debe pintar flecha, y (d) celdas: JSONB ordenado por ordenColumna con una entrada por actividad-columna {ordenColumna, pkTactividad, pkTunidad, pkTactividadEstudiante, estado, calificacion, recuperacion, definitiva, nota, calificable, observacion}. estado distingue explicitamente los CUATRO casos que pinta la pantalla: ''NO_ASIGNADA'' (sin TACTIVIDAD_ESTUDIANTE activo -> el icono de prohibido; pkTactividadEstudiante viene NULL, asi que por construccion no se puede abrir el popover de una celda que no aplica), ''NO_CALIFICABLE'' (asignado pero CALIFICABLE=''N''), ''SIN_CALIFICAR'' y ''CALIFICADA'' (el check). Las columnas y su orden salen de fn_planilla_actividades_universo, el MISMO helper que usa fn_planilla_columnas_listar: header y celdas no pueden desalinearse, y los metadatos de cada actividad NO se repiten por estudiante (van en el header). El toggle "Ver por: Actividad | Unidad" NO cambia esta consulta: es la misma matriz, agrupada en el cliente por pkTunidad. Paginacion por ESTUDIANTE (total_count via COUNT(*) OVER()); los agregados corren solo contra las filas de la pagina. Gate VER sobre PLANEADOR + fn_planilla_grupo_asignatura_assert. V239.';
