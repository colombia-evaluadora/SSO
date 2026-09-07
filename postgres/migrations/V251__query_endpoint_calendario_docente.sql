-- ===========================================================================
-- V251 — Planeador educativo: grilla mensual (calendario) del docente
-- (CU-86e311xxp).
--
-- ORIGEN: la coleccion Postman del front
-- "planeador-listado-stats-calendario" planteo 2 necesidades como
-- "propuestas a confirmar, no implementadas". Al revisarlas contra lo que
-- ya existe:
--
--   (a) "GET /planeador/actividades/stats" (4 tarjetas de resumen)
--       -> NO hace falta un endpoint nuevo: ya existe
--          GET /planeador/actividades/tablero (V250,
--          fn_actividad_resumen_estados_docente), que devuelve los
--          contadores en UNA pasada (COUNT(*) FILTER) en vez del atajo
--          actual del front de traer todo con size=500 y contar en el
--          navegador. El mapeo de los 4 estados de la UI a los estados
--          DERIVADOS reales (fn_actividad_estado) es:
--              pending      -> PENDIENTE_POR_EVALUAR
--              in-progress  -> EN_EVALUACION
--              completed    -> FINALIZADA
--              cancelled    -> VENCIDA        <-- OJO: no es "cancelada".
--          Nada se cancela en el Planeador; la cuarta tarjeta es
--          "Vencidas (> N dias)", y ese N es el parametro ?diasGracia=
--          (default 2) -- por eso la etiqueta de la tarjeta dice "> 2 dias".
--          Ademas el tablero devuelve 2 contadores que el front todavia no
--          pinta (PROGRAMADA y SIN_PROGRAMAR) y el total.
--
--   (b) "GET /planeador/actividades?desde=&hasta=&sinPaginar=true"
--       -> el filtro por rango YA existe en el listado como
--          ?fechaDesde=/?fechaHasta= (V246, fn_actividad_listar), con
--          semantica de SOLAPAMIENTO. Lo que faltaba de verdad era exponer
--          fn_actividad_calendario (V224), que es la funcion hecha a
--          proposito para la grilla: sin paginacion (el rango es un mes,
--          nunca un volumen grande), rango obligatorio y una fila por
--          actividad con lo justo para pintar la celda. Eso es lo que
--          registra este archivo -- no se agregan parametros nuevos al
--          listado general ni un flag "sinPaginar" al motor.
--
-- CAMBIOS A fn_actividad_calendario (V224), pedidos por ese mismo analisis:
--   1. Devuelve tambien FECHA_INICIO y FECHA_CIERRE. Antes solo devolvia
--      `fecha` (el dia resuelto). El front declara que necesita las dos
--      fechas para pintar la celda, asi que se exponen; `fecha` se mantiene
--      como el dia de anclaje ya resuelto (COALESCE(inicio, cierre)) para
--      que el cliente pueda agrupar por dia sin recalcular nada.
--   2. El rango pasa de "el dia de anclaje cae dentro" a SOLAPAMIENTO con
--      [fecha_inicio, fecha_cierre] -- misma semantica que ya usa
--      fn_actividad_listar. Sin esto, una actividad del 28/08 al 10/09 no
--      aparecia en la grilla de septiembre aunque la cruza entera.
--   3. Gana p_fk_tfuncionario (al final de la firma) con el MISMO criterio
--      que V250: el docente que DICTA (TDOCENTE_ASIGNATURA por
--      grupo+asignatura), no el autor de la unidad.
-- Cambia la lista de columnas de RETURNS TABLE, asi que va con DROP previo
-- (CREATE OR REPLACE no puede cambiar el tipo de retorno).
--
-- Y se agrega fn_actividad_calendario_docente, wrapper equivalente a
-- fn_actividad_resumen_estados_docente / fn_actividad_listar_docente (V250):
-- resuelve el docente del token y NO lo expone como parametro.
--
-- Depende de: V224 (fn_actividad_calendario, fn_actividad_estado,
-- fn_funcionario_actual), V250 (patron del tablero del docente), V249
-- (CEVAL-DOCENTE en role_query).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) fn_actividad_calendario — + fechas, + solapamiento, + docente.
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_actividad_calendario(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_calendario(
    p_pk_usuario_solicitante   BIGINT,
    p_fecha_desde              DATE,
    p_fecha_hasta              DATE,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tgrupo                BIGINT  DEFAULT NULL,
    p_fk_tunidad               BIGINT  DEFAULT NULL,
    p_dias_gracia              INT     DEFAULT 2,
    p_fk_tfuncionario          BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    fecha             DATE,
    fecha_inicio      DATE,
    fecha_cierre      DATE,
    pk_tactividad     BIGINT,
    titulo            VARCHAR,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    area              VARCHAR,
    estado            VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF p_fecha_desde IS NULL OR p_fecha_hasta IS NULL THEN
        RAISE EXCEPTION 'El rango de fechas (p_fecha_desde, p_fecha_hasta) es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF p_fecha_hasta < p_fecha_desde THEN
        RAISE EXCEPTION 'p_fecha_hasta (%) no puede ser anterior a p_fecha_desde (%)',
            p_fecha_hasta, p_fecha_desde USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE),
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           ar.NOMBRE,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia)
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar    ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TGRUPO g    ON g.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.ACTIVE = TRUE
       -- V251: SOLAPAMIENTO con el rango, no "el dia de anclaje cae dentro"
       -- (misma semantica que fn_actividad_listar): una actividad del 28/08
       -- al 10/09 tiene que aparecer en la grilla de septiembre.
       AND COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta
       AND COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde
       AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tunidad     IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                 WHERE da.FK_TGRUPO      = a.FK_TGRUPO
                   AND da.FK_TASIGNATURA = a.FK_TASIGNATURA
                   AND da.FK_TFUNCIONARIO = p_fk_tfuncionario
                   AND da.ACTIVE = TRUE))
     ORDER BY 1, g.NOMBRE NULLS LAST, a.TITULO;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_calendario(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT, BIGINT)
    IS 'Actividades de un rango de fechas para la grilla mensual del Planeador: fecha (dia de anclaje ya resuelto = COALESCE(FECHA_INICIO, FECHA_CIERRE), para agrupar por dia sin recalcular), fecha_inicio y fecha_cierre crudas (V251, el front pinta el tramo), titulo, grupo, asignatura, area y estado derivado. Rango OBLIGATORIO y sin paginacion: un mes calendario no es un volumen grande, por eso no se pagina (evita el atajo del front de pedir size=500 y filtrar en el cliente). V251: el rango filtra por SOLAPAMIENTO con [FECHA_INICIO, FECHA_CIERRE] -- misma semantica que fn_actividad_listar -- para que una actividad que cruza el mes aparezca en su grilla; y p_fk_tfuncionario (al final de la firma) acota al docente que DICTA la actividad via TDOCENTE_ASIGNATURA, no al autor de la unidad. Entra por idx_tactividad_asignatura_fechas / idx_tactividad_grupo_fechas. Gate VER sobre PLANEADOR. V224/V251.';

-- ===========================================================================
-- (2) fn_actividad_calendario_docente — wrapper "mi calendario".
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_calendario_docente(
    p_pk_usuario_solicitante   BIGINT,
    p_fecha_desde              DATE,
    p_fecha_hasta              DATE,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tgrupo                BIGINT  DEFAULT NULL,
    p_fk_tunidad               BIGINT  DEFAULT NULL,
    p_dias_gracia              INT     DEFAULT 2
)
RETURNS TABLE (
    fecha             DATE,
    fecha_inicio      DATE,
    fecha_cierre      DATE,
    pk_tactividad     BIGINT,
    titulo            VARCHAR,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    area              VARCHAR,
    estado            VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tfuncionario BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_fk_tfuncionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);

    -- Mismo guard que fn_actividad_listar_docente (V250): sin funcionario NO
    -- se delega con NULL, que en fn_actividad_calendario significa "sin
    -- filtro" y pintaria el calendario de todo el establecimiento.
    IF v_fk_tfuncionario IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_calendario(
        p_pk_usuario_solicitante, p_fecha_desde, p_fecha_hasta,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_dias_gracia,
        v_fk_tfuncionario
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_calendario_docente(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT)
    IS 'Grilla mensual "mi calendario" del docente autenticado: mismas columnas y reglas que fn_actividad_calendario, SIEMPRE acotada a su propio FK_TFUNCIONARIO (fn_funcionario_actual) -- nunca editable por el cliente. Si el usuario autenticado no es un docente activo devuelve 0 filas (guard explicito: delegar con NULL significaria "sin filtro" y expondria el calendario completo). Completa el trio del tablero del docente junto a fn_actividad_resumen_estados_docente (tarjetas) y fn_actividad_listar_docente (listado), los tres sobre la misma derivacion de estado (fn_actividad_estado). Gate VER sobre PLANEADOR. V251.';

-- ===========================================================================
-- (3) ENDPOINT — GET /planeador/actividades/calendario
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_calendario_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/calendario', 'SELECT', 'GET',
    '{"QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.DIAS_GRACIA": "INT"}'::jsonb,
    'V251 -- grilla mensual del calendario del Planeador para el DOCENTE autenticado (fn_actividad_calendario_docente, V251). ?fechaDesde= y ?fechaHasta= son OBLIGATORIOS (22023 si falta alguno, o si hasta < desde) y acotan por SOLAPAMIENTO con [fecha_inicio, fecha_cierre]: una actividad que cruza el mes aparece en su grilla. SIN paginacion -- un mes nunca es un volumen grande, por eso NO hay que mandar ?size=/?offset= aqui (sustituye el atajo del front de pedir el listado completo con size=500 y filtrar el mes en el cliente). Cada fila trae: fecha (dia de anclaje ya resuelto, para agrupar por dia sin recalcular), fecha_inicio, fecha_cierre, pk_tactividad, titulo, fk_tgrupo + grupo, fk_tasignatura + asignatura, area y estado DERIVADO (mismo fn_actividad_estado del tablero y del listado, con ?diasGracia= default 2). El docente se resuelve del token y NO es un parametro: nadie pinta el calendario de otro docente por esta ruta; si el usuario no es docente activo, 0 filas. Filtros opcionales ?asignatura=, ?grupo=, ?unidad=. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/actividades/calendario'
ON CONFLICT DO NOTHING;
