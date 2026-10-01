-- ===========================================================================
-- V528 — fn_actividad_calendario/_docente: mismo filtro por pares (grado,
-- asignatura) de una pestaña de Rotulo de Ejecucion que V526/V527 ya dieron
-- a GET /planeador/actividades/mias. La grilla mensual (GET /planeador/
-- actividades/calendario) seguia sin el filtro, asi que mostraba
-- actividades de TODOS los rotulos del docente mezcladas en el mismo mes.
-- Mismo contrato que V526: VARCHAR[] de "grado:asignatura" (asignatura
-- vacio = comodin), nunca JSONB (QUERY.* de un GET no admite array/objeto).
-- Depende de: V251 (fn_actividad_calendario/_docente), V526/V527 (patron,
-- mismo p_grado_asignatura_pares en el listado).
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_calendario(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_calendario_docente(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_calendario(
    p_pk_usuario_solicitante   BIGINT,
    p_fecha_desde              DATE,
    p_fecha_hasta              DATE,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL
)
RETURNS TABLE (
    fecha             DATE,
    fecha_inicio      DATE,
    fecha_cierre      DATE,
    pk_tactividad     BIGINT,
    titulo            VARCHAR,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tgrado         BIGINT,
    grado             VARCHAR,
    grado_codigo      VARCHAR,
    grado_grupo       VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    area              VARCHAR,
    estado            VARCHAR,
    etiqueta          VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sedes_lectura BIGINT[];
    v_alcance_total BOOLEAN;
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_alcance_total := COALESCE(
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1;
    v_sedes_lectura := ARRAY(
        SELECT sl.sede_id
          FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl);

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
           gr.PK_TGRADO,
           gr.NOMBRE,
           gr.CODIGO,
           academico_test.fn_grado_grupo_etiqueta(gr.NOMBRE, gr.CODIGO, g.NOMBRE),
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           ar.NOMBRE,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia),
           (COALESCE(academico_test.fn_grado_grupo_etiqueta(gr.NOMBRE, gr.CODIGO, g.NOMBRE) || ' · ', '')
            || a.TITULO)::VARCHAR
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar    ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TGRUPO g    ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TUNIDAD u_g ON u_g.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRADO gr   ON gr.PK_TGRADO = COALESCE(g.FK_TGRADO, u_g.FK_TGRADO)
     WHERE a.ACTIVE = TRUE
           AND (
                 EXISTS (SELECT 1
                           FROM academico_test.TGRUPO g_sc
                           JOIN academico_test.TGRADO gr_sc
                             ON gr_sc.PK_TGRADO = g_sc.FK_TGRADO
                           JOIN academico_test.TPERIODO_ACADEMICO pa_sc
                             ON pa_sc.PK_TPERIODO_ACADEMICO = gr_sc.FK_TPERIODO_ACADEMICO
                           JOIN academico_test.TSEDE s_sc
                             ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                          WHERE g_sc.PK_TGRUPO = a.FK_TGRUPO
                            AND (v_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
              OR EXISTS (SELECT 1
                           FROM academico_test.TUNIDAD u_sc
                           JOIN academico_test.TGRADO gr_sc
                             ON gr_sc.PK_TGRADO = u_sc.FK_TGRADO
                           JOIN academico_test.TPERIODO_ACADEMICO pa_sc
                             ON pa_sc.PK_TPERIODO_ACADEMICO = gr_sc.FK_TPERIODO_ACADEMICO
                           JOIN academico_test.TSEDE s_sc
                             ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                          WHERE u_sc.PK_TUNIDAD = a.FK_TUNIDAD
                            AND (v_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
              OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                  AND (v_alcance_total
                       OR a.CREATED_BY = p_pk_usuario_solicitante::VARCHAR))
               )
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
       -- V528: pestaña de Rotulo de Ejecucion activa, mismo contrato que
       -- fn_actividad_listar_interno (V526) -- ver cabecera.
       AND (p_grado_asignatura_pares IS NULL OR EXISTS (
               SELECT 1
                 FROM unnest(p_grado_asignatura_pares) AS par(valor)
                WHERE split_part(par.valor, ':', 1)::BIGINT = gr.PK_TGRADO
                  AND (
                        split_part(par.valor, ':', 2) = ''
                     OR split_part(par.valor, ':', 2)::BIGINT = a.FK_TASIGNATURA
                  )
           ))
     ORDER BY 1, g.NOMBRE NULLS LAST, a.TITULO;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_calendario(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT, BIGINT, VARCHAR[])
    IS 'etiqueta = grado/grupo + titulo ("601 · Debate"): va en la CELDA del calendario. Actividades de un rango de fechas para la grilla mensual del Planeador: fecha (dia de anclaje ya resuelto), fecha_inicio/fecha_cierre crudas, titulo, grupo, asignatura, area y estado derivado. Rango OBLIGATORIO y sin paginacion. El rango filtra por SOLAPAMIENTO con [FECHA_INICIO, FECHA_CIERRE]; p_fk_tfuncionario acota al docente que DICTA via TDOCENTE_ASIGNATURA. p_grado_asignatura_pares (V528): acota a una pestaña de Rotulo de Ejecucion (fn_planeador_actividad_tabs_listar, V525) -- VARCHAR[] de "grado:asignatura" (asignatura vacío = comodín), mismo contrato que fn_actividad_listar_interno (V526), nunca JSONB. Gate VER sobre PLANEADOR. V224/V251/V528.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_calendario_docente(
    p_pk_usuario_solicitante   BIGINT,
    p_fecha_desde              DATE,
    p_fecha_hasta              DATE,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL
)
RETURNS TABLE (
    fecha             DATE,
    fecha_inicio      DATE,
    fecha_cierre      DATE,
    pk_tactividad     BIGINT,
    titulo            VARCHAR,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tgrado         BIGINT,
    grado             VARCHAR,
    grado_codigo      VARCHAR,
    grado_grupo       VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    area              VARCHAR,
    estado            VARCHAR,
    etiqueta          VARCHAR
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

    IF v_fk_tfuncionario IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_calendario(
        p_pk_usuario_solicitante, p_fecha_desde, p_fecha_hasta,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_dias_gracia,
        v_fk_tfuncionario, p_grado_asignatura_pares
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_calendario_docente(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT, VARCHAR[])
    IS 'Grilla mensual "mi calendario" del docente autenticado: mismas columnas y reglas que fn_actividad_calendario, SIEMPRE acotada a su propio FK_TFUNCIONARIO. Si el usuario autenticado no es un docente activo devuelve 0 filas. p_grado_asignatura_pares (V528): acota a una pestaña de Rotulo de Ejecucion, mismo contrato que fn_actividad_listar_docente (V526/V527). Gate VER sobre PLANEADOR. V251/V528.';
