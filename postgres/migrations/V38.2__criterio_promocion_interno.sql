-- ===========================================================================
-- V38.2 -- Criterios de promocion: nucleos _interno
-- ===========================================================================
-- QUE HACE: guardar (alta o edicion del criterio general del periodo o del
-- override de un grado, con su lista de obligatorias) y obtener, sin permisos.
-- Validan con V38.1 antes de escribir; el gate y la auditoria van en V38.3.
-- POR QUE AQUI: capa 2 del modulo (V38.1 / V38.2 / V38.3).
-- DEPENDE DE: V22, V38.1.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Los NULL conservan el valor actual; p_obligatorias NULL no toca la lista.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar_interno(
    p_fk_periodo BIGINT,
    p_fk_grado BIGINT,
    p_nodo_curricular academico_test.nodo_curricular,
    p_cantidad_nivelar NUMERIC,
    p_asignatura_obligatoria academico_test.bool_sn,
    p_aprobacion_promedio academico_test.bool_sn,
    p_desempenho_min_general NUMERIC,
    p_desempenho_minimo NUMERIC,
    p_max_asig_promedio NUMERIC,
    p_minimo_inasistencias NUMERIC,
    p_max_asig_nivelar_prom NUMERIC,
    p_obligatorias BIGINT[],
    p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
    d    academico_test.TCRITERIO_PROMOCION;
    v_pk BIGINT;
BEGIN
    PERFORM academico_test.fn_criterio_prom_validar_no_negativos(p_cantidad_nivelar, p_desempenho_min_general,
        p_desempenho_minimo, p_max_asig_promedio, p_minimo_inasistencias, p_max_asig_nivelar_prom);

    -- El override de grado se busca solo por grado: el grado ya fija el periodo.
    IF p_fk_grado IS NULL THEN
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
    ELSE
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    END IF;

    IF v_id IS NULL THEN
        -- Un override nuevo hereda del criterio general del periodo lo que no venga.
        IF p_fk_grado IS NOT NULL THEN
            SELECT * INTO d FROM academico_test.TCRITERIO_PROMOCION
             WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
        END IF;
        INSERT INTO academico_test.TCRITERIO_PROMOCION (
            FK_TPERIODO_ACADEMICO, FK_TGRADO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
            ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
            DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, MINIMO_INASISTENCIAS,
            MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY
        ) VALUES (
            p_fk_periodo, p_fk_grado,
            COALESCE(p_nodo_curricular, d.NODO_CURRICULAR),
            COALESCE(p_cantidad_nivelar, d.CANTIDAD_NIVELAR, 0),
            COALESCE(p_asignatura_obligatoria, d.ASIGNATURA_OBLIGATORIA),
            COALESCE(p_aprobacion_promedio, d.APROBACION_PROMEDIO),
            COALESCE(p_desempenho_min_general, d.DESEMPENHO_MINIMO_GENERAL),
            COALESCE(p_desempenho_minimo, d.DESEMPENHO_MINIMO),
            COALESCE(p_max_asig_promedio, d.MAX_ASIG_PROMEDIO),
            COALESCE(p_minimo_inasistencias, d.MINIMO_INASISTENCIAS),
            COALESCE(p_max_asig_nivelar_prom, d.MAX_ASIG_NIVELAR_PROMOVIDO),
            CASE WHEN p_fk_grado IS NULL THEN 'S' ELSE 'N' END::academico_test.bool_sn, p_audit
        )
        RETURNING PK_TCRITERIO_PROMOCION INTO v_id;
    ELSE
        UPDATE academico_test.TCRITERIO_PROMOCION SET
            NODO_CURRICULAR = COALESCE(p_nodo_curricular, NODO_CURRICULAR),
            CANTIDAD_NIVELAR = COALESCE(p_cantidad_nivelar, CANTIDAD_NIVELAR),
            ASIGNATURA_OBLIGATORIA = COALESCE(p_asignatura_obligatoria, ASIGNATURA_OBLIGATORIA),
            APROBACION_PROMEDIO = COALESCE(p_aprobacion_promedio, APROBACION_PROMEDIO),
            DESEMPENHO_MINIMO_GENERAL = COALESCE(p_desempenho_min_general, DESEMPENHO_MINIMO_GENERAL),
            DESEMPENHO_MINIMO = COALESCE(p_desempenho_minimo, DESEMPENHO_MINIMO),
            MAX_ASIG_PROMEDIO = COALESCE(p_max_asig_promedio, MAX_ASIG_PROMEDIO),
            MINIMO_INASISTENCIAS = COALESCE(p_minimo_inasistencias, MINIMO_INASISTENCIAS),
            MAX_ASIG_NIVELAR_PROMOVIDO = COALESCE(p_max_asig_nivelar_prom, MAX_ASIG_NIVELAR_PROMOVIDO),
            MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TCRITERIO_PROMOCION = v_id;
    END IF;

    -- Reescribe el set completo; p_nodo_curricular dice si los ids son asignaturas o areas.
    IF p_obligatorias IS NOT NULL THEN
        UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE;

        FOREACH v_pk IN ARRAY p_obligatorias LOOP
            PERFORM academico_test.fn_criterio_prom_validar_obligatoria(p_fk_periodo, v_id, p_nodo_curricular, v_pk);
            INSERT INTO academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                (FK_TCRITERIO_PROMOCION, FK_TASIGNATURA, FK_TAREA, CREATED_BY)
            VALUES (v_id,
                    CASE WHEN p_nodo_curricular = 'AS' THEN v_pk END,
                    CASE WHEN p_nodo_curricular = 'AR' THEN v_pk END,
                    p_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_prom_guardar_interno(BIGINT, BIGINT, academico_test.nodo_curricular, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, BIGINT[], VARCHAR)
    IS 'INTERNO: alta o edicion del criterio de promocion (general del periodo si p_fk_grado es NULL, override del grado si no) y reescritura de sus obligatorias. Lo usa fn_criterio_prom_guardar.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_obtener_interno(
    p_fk_periodo BIGINT, p_fk_grado BIGINT
)
RETURNS TABLE (
    id BIGINT, academic_period_id BIGINT, grade_id BIGINT, curriculum_node academico_test.nodo_curricular,
    max_failed_recovery NUMERIC, asignatura_obligatoria academico_test.bool_sn,
    apply_average_approval academico_test.bool_sn, base_percentage NUMERIC,
    minimum_subject_percentage NUMERIC, max_failed_for_average NUMERIC,
    absence_percentage NUMERIC, max_leveled_subjects NUMERIC, mandatory_subjects JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT cp.PK_TCRITERIO_PROMOCION, cp.FK_TPERIODO_ACADEMICO, cp.FK_TGRADO,
           cp.NODO_CURRICULAR, cp.CANTIDAD_NIVELAR, cp.ASIGNATURA_OBLIGATORIA,
           cp.APROBACION_PROMEDIO, cp.DESEMPENHO_MINIMO_GENERAL, cp.DESEMPENHO_MINIMO,
           cp.MAX_ASIG_PROMEDIO, cp.MINIMO_INASISTENCIAS, cp.MAX_ASIG_NIVELAR_PROMOVIDO,
           -- Para una asignatura el area se deriva de TASIGNATURA.FK_TAREA, no se guarda.
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'id', o.PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA,
                          'type', CASE WHEN o.FK_TASIGNATURA IS NOT NULL THEN 'subject' ELSE 'area' END,
                          'subjectId', o.FK_TASIGNATURA,
                          'subjectName', s.NOMBRE,
                          'areaId', COALESCE(o.FK_TAREA, s.FK_TAREA),
                          'areaName', COALESCE(ar.NOMBRE, sar.NOMBRE))
                          ORDER BY o.PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA)
                 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA o
                 LEFT JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = o.FK_TASIGNATURA
                 LEFT JOIN academico_test.TAREA sar ON sar.PK_TAREA = s.FK_TAREA
                 LEFT JOIN academico_test.TAREA ar  ON ar.PK_TAREA = o.FK_TAREA
                WHERE o.FK_TCRITERIO_PROMOCION = cp.PK_TCRITERIO_PROMOCION AND o.ACTIVE = TRUE),
               '[]'::jsonb)
      FROM academico_test.TCRITERIO_PROMOCION cp
     WHERE cp.ACTIVE = TRUE
       AND ( (p_fk_grado IS NOT NULL AND cp.FK_TGRADO = p_fk_grado)
          OR (p_fk_grado IS NULL AND cp.FK_TPERIODO_ACADEMICO = p_fk_periodo AND cp.FK_TGRADO IS NULL) );
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_prom_obtener_interno(BIGINT, BIGINT)
    IS 'INTERNO: criterio de promocion activo del grado (si p_fk_grado) o el general del periodo, con sus obligatorias, sin alcance. Lo usa fn_criterio_prom_obtener.';
