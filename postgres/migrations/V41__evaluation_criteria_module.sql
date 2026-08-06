-- ===========================================================================
-- V41 — Modulo de Criterio de Evaluacion (academico_test). Convencion de
-- funciones (ver V37). La fila ya nace al crear el periodo (fn_periodo_crear,
-- V37) con PK compartida = PK del periodo. Aca solo detalle + actualizacion.
-- FK_TESCALA es nullable (depende de escalas de valoracion creadas).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- fn_escala_propagar — cuando se elige una escala de valoracion como la del
-- criterio del periodo, esa escala se vuelve la maestra: sus valoraciones se
-- copian a TODAS las demas escalas del periodo (via TNIVEL_ESCALA), reemplazando
-- por completo las que cada una tuviera. Se hace DELETE de las bandas de cada
-- escala destino (hard delete: evita chocar con los UNIQUE de
-- TESCALA_VALORACION al reinsertar) y se insertan copias frescas (nuevas
-- TVALORACION por-banda) del maestro.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_escala_propagar(
    p_pk_periodo BIGINT, p_fk_escala_source BIGINT, p_audit VARCHAR
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_target BIGINT; v_orden INT; v_new_val BIGINT; sb RECORD;
BEGIN
    -- Si el maestro no tiene bandas activas, no propagar (no vaciar las demas).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESCALA_VALORACION
         WHERE FK_TESCALA = p_fk_escala_source AND ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;

    FOR v_target IN
        SELECT DISTINCT ne.FK_TESCALA FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_pk_periodo AND ne.ACTIVE = TRUE
           AND ne.FK_TESCALA <> p_fk_escala_source
    LOOP
        -- No pisar una escala cuyas bandas ya esten en uso por criterios de
        -- unidad (el DELETE violaria la FK y ademas destruiria datos calificados).
        IF EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
              JOIN academico_test.TESCALA_VALORACION ev2
                ON ev2.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
             WHERE ev2.FK_TESCALA = v_target
        ) THEN
            CONTINUE;
        END IF;
        -- Borrar las TVALORACION de las bandas del destino: cascada-borra sus
        -- TESCALA_VALORACION y no deja valoraciones huerfanas.
        DELETE FROM academico_test.TVALORACION
         WHERE PK_TVALORACION IN (
             SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_target
         );
        v_orden := 0;
        FOR sb IN
            SELECT ev.FK_TVL_TIPO_VALORACION AS tipo, ev.LIMITE_INFERIOR AS li,
                   ev.LIMITE_SUPERIOR AS ls, ev.LIMITE_PROMEDIO AS lp,
                   v.NOMBRE, v.CODIGO, v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO
              FROM academico_test.TESCALA_VALORACION ev
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = ev.FK_TVALORACION
             WHERE ev.FK_TESCALA = p_fk_escala_source AND ev.ACTIVE = TRUE
             ORDER BY ev.ORDEN
        LOOP
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (sb.CODIGO, sb.NOMBRE, sb.tipo, sb.GRAFICA_CARITAS, sb.GRAFICA_SIMBOLO, p_audit)
            RETURNING PK_TVALORACION INTO v_new_val;
            v_orden := v_orden + 1;
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_target, v_new_val, sb.tipo, v_orden, sb.li, sb.ls, sb.lp, p_audit);
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_obtener(p_pk_periodo BIGINT)
RETURNS TABLE (
    academic_period_id BIGINT, grading_format BIGINT, grading_scale BIGINT,
    period_calculation_elements BIGINT, subject_grade_criteria BIGINT,
    final_grade_criteria BIGINT, area_grade_criteria BIGINT,
    student_without_grades_performance BIGINT, rounding_mode NUMERIC, initial_grade NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT ce.PK_TCRITERIO_EVALUACION, ce.FK_TLV_FORMATO_CALIFICACION, ce.FK_TESCALA,
           ce.FK_TLV_ELEMENTO_DEF, ce.FK_TLV_MODIF_FINAL_PERACA, ce.FK_TLV_CRITERIO_FINAL,
           ce.FK_TLV_CRITERIO_AREA, ce.FK_TLV_DESEMPENO_SIN_CALIF, ce.NUMERO_DECIMALES,
           ce.PORCENTAJE_INICIAL_CALIF
      FROM academico_test.TCRITERIO_EVALUACION ce
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_periodo AND ce.ACTIVE = TRUE;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo             BIGINT,
    p_grading_format         BIGINT DEFAULT NULL,
    p_grading_scale          BIGINT DEFAULT NULL,   -- nullable a proposito
    p_set_grading_scale      BOOLEAN DEFAULT FALSE, -- TRUE = aplicar p_grading_scale (incl. NULL)
    p_period_calc_elements   BIGINT DEFAULT NULL,
    p_subject_grade_criteria BIGINT DEFAULT NULL,
    p_final_grade_criteria   BIGINT DEFAULT NULL,
    p_area_grade_criteria    BIGINT DEFAULT NULL,
    p_student_wo_grades      BIGINT DEFAULT NULL,
    p_rounding_mode          NUMERIC DEFAULT NULL,
    p_initial_grade          NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- FK_TESCALA solo cambia si p_set_grading_scale = TRUE (permite ponerla o
    -- limpiarla explicitamente); en FALSE no se toca. El resto es COALESCE.
    -- Si se va a asignar una escala no nula, debe existir y estar activa.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala de valoracion % no existe o esta inactiva', p_grading_scale USING ERRCODE = '23503';
        END IF;
        -- La escala maestra debe pertenecer al periodo (estar ligada via TNIVEL_ESCALA).
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = p_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala % no pertenece al periodo academico %', p_grading_scale, p_pk_periodo
                USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Escala maestra actual (para decidir si hay que propagar).
    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN p_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_subject_grade_criteria, FK_TLV_MODIF_FINAL_PERACA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_rounding_mode, NUMERO_DECIMALES),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade, PORCENTAJE_INICIAL_CALIF),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo %', p_pk_periodo
            USING ERRCODE = 'P0002';
    END IF;

    -- Solo al ELEGIR una escala maestra distinta a la actual se propaga a las
    -- demas escalas del periodo. Guardar otros campos (o re-guardar la misma
    -- escala) no vuelve a pisar las personalizaciones de las otras escalas.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, p_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;
