-- ===========================================================================
-- V335 - fn informe grupo listar
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


-- La vigente es posterior; esta solo hace falta en una base limpia (V411:migracion, V411:migracion).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_informe_grupo_listar(bigint,bigint,bigint[],varchar)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula               BIGINT,
    estudiante                  VARCHAR,
    documento                   VARCHAR,
    fk_tperiodo_evaluacion      BIGINT,
    periodo_nombre              VARCHAR,
    periodo_abreviacion         VARCHAR,
    periodo_inicio              DATE,
    formato                     VARCHAR,
    es_cualitativo              BOOLEAN,
    consolidado                 BOOLEAN,
    promedio_guardado           NUMERIC,
    promedio_proyectado         NUMERIC,
    puesto                      BIGINT,
    asignaturas_total           BIGINT,
    aprobadas                   BIGINT,
    reprobadas                  BIGINT,
    sin_definir                 BIGINT,
    tiene_cambios_propuestos    BOOLEAN,
    asignaturas                 JSONB,
    observacion                 TEXT,
    observacion_estado          VARCHAR,
    observacion_desactualizada  BOOLEAN,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    estudiantes AS (
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    ),
    -- Todo el detalle del grupo, de una sola vez. Un LATERAL por estudiante
    -- sobre fn_informe_estudiante_asignaturas (V334) en vez de reimplementar
    -- las formulas: mas caro -- una llamada y un gate por estudiante -- pero
    -- imposibilita que la LISTA y el DETALLE se contradigan, un bug invisible
    -- hasta que alguien reclama que la tabla dice 3,8 y las notas promedian
    -- 3,9. Los grupos son de decenas; si algun dia no alcanza, lo correcto es
    -- materializar el detalle, no duplicar la formula.
    detalle AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, p_fk_periodos_evaluacion) d
    ),
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk    AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               -- Metricas calculadas al vuelo, para cuando aun no se consolido.
               COUNT(d.fk_tasignatura)                             AS calc_total,
               AVG(d.nota_guardada)                                AS calc_prom_guardado,
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada))   AS calc_prom_visible,
               COUNT(*) FILTER (WHERE d.aprobada IS TRUE)          AS calc_aprob,
               COUNT(*) FILTER (WHERE d.aprobada IS FALSE)         AS calc_reprob,
               COUNT(*) FILTER (WHERE d.fk_tasignatura IS NOT NULL
                                  AND d.aprobada IS NULL)          AS calc_sindef,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)             AS hay_numerico,
               COALESCE(BOOL_OR(d.estado_nota = 'cambio_propuesto'), FALSE) AS cambios,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',  d.fk_tasignatura,
                           'nombre',      d.asignatura_nombre,
                           'abreviacion', asg.ABREVIACION,
                           'area',        d.area_nombre,
                           'orden',       asg.ORDEN_REPORTE,
                           'nota',        d.nota_homologada,
                           -- Solo cuando hay algo que proponer. NULL con
                           -- estado 'cambio_propuesto' significa "ya no hay
                           -- nota", no "no hay propuesta".
                           'nota_propuesta',
                               CASE WHEN d.estado_nota = 'cambio_propuesto'
                                    THEN d.nota_proyectada_homologada END,
                           'estado',      d.estado_nota,
                           'es_numerico', d.es_numerico,
                           'valoracion',  d.valoracion_nombre,
                           'simbolo',     d.valoracion_simbolo,
                           'aprobada',    d.aprobada
                       ) ORDER BY asg.ORDEN_REPORTE NULLS LAST, d.asignatura_nombre
                   ) FILTER (WHERE d.fk_tasignatura IS NOT NULL),
                   '[]'::JSONB
               ) AS asigs
          FROM estudiantes e
          CROSS JOIN periodos p
          LEFT JOIN detalle d
                 ON d.mat = e.pk
                AND d.fk_tperiodo_evaluacion = p.pk
          LEFT JOIN academico_test.TASIGNATURA asg
                 ON asg.PK_TASIGNATURA = d.fk_tasignatura
         GROUP BY e.pk, e.nombre, e.doc, p.pk, p.nombre, p.abrev, p.inicio
    ),
    con_metricas AS (
        SELECT pp.*,
               (ipm.PK_TINFORME_PERIODO_MATRICULA IS NOT NULL) AS esta_consolidado,
               -- Guardadas si existen, calculadas si no.
               COALESCE(ipm.PROMEDIO,    ROUND(pp.calc_prom_guardado, 2)) AS prom_guardado,
               COALESCE(ipm.ASIGNATURAS, pp.calc_total)                   AS total_asig,
               COALESCE(ipm.APROBADAS,   pp.calc_aprob)                   AS aprob,
               COALESCE(ipm.REPROBADAS,  pp.calc_reprob)                  AS reprob,
               COALESCE(ipm.SIN_DEFINIR, pp.calc_sindef)                  AS sindef,
               ob.OBSERVACION                                             AS obs,
               lv.VALOR                                                   AS obs_estado,
               CASE WHEN ob.PK_TESTUDIANTE_PERIODO_OBSERVACION IS NULL THEN NULL
                    ELSE COALESCE(hoy.n, 0) > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
               END                                                        AS obs_vieja
          FROM por_periodo pp
          LEFT JOIN academico_test.TINFORME_PERIODO_MATRICULA ipm
                 ON ipm.FK_TMATRICULA          = pp.mat
                AND ipm.FK_TPERIODO_EVALUACION = pp.pe
                AND ipm.ACTIVE = TRUE
          LEFT JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
                 ON ob.FK_TMATRICULA          = pp.mat
                AND ob.FK_TPERIODO_EVALUACION = pp.pe
                AND ob.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
          LEFT JOIN LATERAL (
                SELECT COUNT(*) AS n
                  FROM academico_test.TACTIVIDAD a2
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                    ON ae2.FK_TACTIVIDAD = a2.PK_TACTIVIDAD
                   AND ae2.FK_TMATRICULA = pp.mat
                   AND ae2.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n2
                    ON n2.FK_TACTIVIDAD_ESTUDIANTE = ae2.PK_TACTIVIDAD_ESTUDIANTE
                   AND n2.ACTIVE = TRUE
                 WHERE a2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(n2.OBSERVACION, '')), '') IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a2.PK_TACTIVIDAD, pp.pe) = TRUE
          ) hoy ON TRUE
    ),
    con_puesto AS (
        -- El puesto se calcula ANTES del filtro de busqueda: buscar a un
        -- estudiante no debe cambiar su posicion en el grupo. Y se particiona
        -- por periodo, porque el puesto es del periodo.
        SELECT cm.*,
               CASE WHEN cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC)
               END AS pos
          FROM con_metricas cm
    )
    SELECT cp.mat,
           cp.nombre,
           cp.doc,
           cp.pe,
           cp.pe_nombre,
           cp.pe_abrev,
           cp.pe_inicio,
           CASE WHEN cp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
           NOT cp.hay_numerico,
           cp.esta_consolidado,
           cp.prom_guardado,
           ROUND(cp.calc_prom_visible, 2),
           cp.pos,
           cp.total_asig::BIGINT,
           cp.aprob::BIGINT,
           cp.reprob::BIGINT,
           cp.sindef::BIGINT,
           cp.cambios,
           cp.asigs,
           cp.obs,
           cp.obs_estado,
           cp.obs_vieja,
           COUNT(*) OVER ()::BIGINT
      FROM con_puesto cp
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR cp.nombre ILIKE '%' || TRIM(p_search) || '%'
        OR cp.doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY cp.nombre NULLS LAST, cp.mat, cp.pe_inicio;
END;
$function$$crear$;
    END IF;
END $guarda$;

