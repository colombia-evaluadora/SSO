-- ===========================================================================
-- V530 — fn_actividad_resumen_estados/_docente: mismo filtro por pares
-- (grado, asignatura) de una pestaña de Rotulo de Ejecucion que V526/V528 ya
-- dieron al listado y al calendario. Las 4 tarjetas del tablero ("Pendientes
-- por evaluar"/"En evaluacion"/"Finalizadas"/"Vencidas") seguian sumando
-- TODOS los rotulos del docente, asi que no cambiaban al moverse entre
-- pestañas.
-- Mismo contrato que V526/V528: VARCHAR[] de "grado:asignatura" (asignatura
-- vacio = comodin), nunca JSONB.
-- Depende de: V224/V250 (fn_actividad_resumen_estados/_docente), V526/V528
-- (patron, mismo p_grado_asignatura_pares).
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_resumen_estados_docente(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_resumen_estados_docente(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT, VARCHAR[]);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_resumen_estados(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resumen_estados(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_fecha_desde              DATE      DEFAULT NULL,
    p_fecha_hasta              DATE      DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL
)
RETURNS TABLE (
    pendientes_por_evaluar  BIGINT,
    en_evaluacion           BIGINT,
    finalizadas             BIGINT,
    vencidas                BIGINT,
    total                   BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sedes_lectura BIGINT[];
    v_alcance_total BOOLEAN;
    v_periodos_lectura BIGINT[];
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Mismo alcance que los listados; en nivel 3, solo sus pares sede+jornada.
    SELECT alc.alcance_total, alc.sedes_lectura, alc.periodos_lectura
      INTO v_alcance_total, v_sedes_lectura, v_periodos_lectura
      FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante) alc;

    RETURN QUERY
    WITH est AS (
        SELECT academico_test.fn_actividad_estado(
                   a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia
               ) AS estado
          FROM academico_test.TACTIVIDAD a
          -- V530: grado efectivo (via grupo, o si no tiene, via su unidad) --
          -- mismo criterio que fn_actividad_listar_interno/fn_actividad_calendario.
          LEFT JOIN academico_test.TGRUPO g_ga  ON g_ga.PK_TGRUPO = a.FK_TGRUPO
          LEFT JOIN academico_test.TUNIDAD u_ga ON u_ga.PK_TUNIDAD = a.FK_TUNIDAD
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
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura))
                            AND (v_periodos_lectura IS NULL
                                 OR pa_sc.PK_TPERIODO_ACADEMICO = ANY(v_periodos_lectura)))
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
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura))
                            AND (v_periodos_lectura IS NULL
                                 OR pa_sc.PK_TPERIODO_ACADEMICO = ANY(v_periodos_lectura)))
              OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                  AND (v_alcance_total
                       OR a.CREATED_BY = p_pk_usuario_solicitante::VARCHAR))
               )
           AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fk_tunidad     IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
           AND (p_fk_tfuncionario IS NULL OR EXISTS (
                    SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                     WHERE da.FK_TGRUPO      = a.FK_TGRUPO
                       AND da.FK_TASIGNATURA = a.FK_TASIGNATURA
                       AND da.FK_TFUNCIONARIO = p_fk_tfuncionario
                       AND da.ACTIVE = TRUE))
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
           -- V530: pestaña de Rotulo de Ejecucion activa, mismo contrato que
           -- fn_actividad_listar_interno (V526) / fn_actividad_calendario (V528).
           AND (p_grado_asignatura_pares IS NULL OR EXISTS (
                   SELECT 1
                     FROM unnest(p_grado_asignatura_pares) AS par(valor)
                    WHERE split_part(par.valor, ':', 1)::BIGINT = COALESCE(g_ga.FK_TGRADO, u_ga.FK_TGRADO)
                      AND (
                            split_part(par.valor, ':', 2) = ''
                         OR split_part(par.valor, ':', 2)::BIGINT = a.FK_TASIGNATURA
                      )
               ))
    )
    SELECT COUNT(*) FILTER (WHERE estado = 'PENDIENTE_POR_EVALUAR')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'EN_EVALUACION')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'FINALIZADA')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'VENCIDA')::BIGINT,
           COUNT(*)::BIGINT
      FROM est;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_resumen_estados(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT, BIGINT, VARCHAR[])
    IS 'Contadores del tablero del Planeador (Pendientes por evaluar / En evaluacion vigentes / Finalizadas / Vencidas > p_dias_gracia dias) en UNA sola pasada con COUNT(*) FILTER sobre el estado derivado por fn_actividad_estado. Filtros opcionales por asignatura, grupo, unidad, ventana de fechas, docente que DICTA (p_fk_tfuncionario) y (V530) pestaña de Rotulo de Ejecucion activa: p_grado_asignatura_pares, VARCHAR[] de "grado:asignatura" (asignatura vacío = comodín), mismo contrato que fn_actividad_listar_interno (V526)/fn_actividad_calendario (V528), nunca JSONB. Gate VER sobre PLANEADOR. V224/V250/V530. Alcance via fn_planeador_alcance_docente: en nivel 3 solo periodos de sus pares sede+jornada.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resumen_estados_docente(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_fecha_desde              DATE      DEFAULT NULL,
    p_fecha_hasta              DATE      DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL
)
RETURNS TABLE (
    pendientes_por_evaluar  BIGINT,
    en_evaluacion           BIGINT,
    finalizadas             BIGINT,
    vencidas                BIGINT,
    total                   BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc
      FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante, p_fk_tfuncionario);

    IF v_alc.fk_tfuncionario IS NULL AND (v_alc.solo_propias OR v_alc.alcance_total) THEN
        RETURN QUERY SELECT 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_resumen_estados(
        p_pk_usuario_solicitante, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad,
        p_fecha_desde, p_fecha_hasta, p_dias_gracia, v_alc.fk_tfuncionario,
        p_grado_asignatura_pares
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_resumen_estados_docente(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT, VARCHAR[], BIGINT)
    IS 'Tablero del Planeador (las CUATRO tarjetas, mas el total). Wrapper delgado: resuelve el docente con fn_planeador_alcance_docente y delega en fn_actividad_resumen_estados. Docente puro: el suyo (ignora p_fk_tfuncionario; sin funcionario, contadores en 0). Otros con p_fk_tfuncionario (?funcionario=): ese docente, 42501 si no dicta nada en su alcance. Otros sin él: todo su alcance (nivel 3: pares sede+jornada); alcance total sin docente elegido: contadores en 0. p_grado_asignatura_pares (V530): acota a una pestaña de Rotulo de Ejecucion, mismo contrato que fn_actividad_listar_docente (V526/V527)/fn_actividad_calendario_docente (V528/V529). Gate VER sobre PLANEADOR. V250/V530.';
