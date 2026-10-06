-- ===========================================================================
-- V41.3 -- Criterios de evaluacion: nucleos _interno
-- ===========================================================================
-- QUE HACE: actualizar y obtener los criterios de evaluacion de un periodo
-- academico, sin permisos. Validan con V41.2 antes de escribir; el gate, la
-- existencia y la auditoria van en V41.4.
-- POR QUE AQUI: capa 2 del modulo (V41.2 / V41.3 / V41.4).
-- DEPENDE DE: V22, V41 (columnas), V41.2, fn_escala_propagar (escalas, enlace tardio).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Las notas se guardan como % del maximo del formato (5, 10 o 100) y se muestran
-- en la escala del formato; el formato se reconoce por TLISTA_VALOR.NOMBRE.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar_interno(
    p_pk_periodo BIGINT,
    p_grading_format BIGINT,
    p_grading_scale BIGINT,
    p_set_grading_scale BOOLEAN,
    p_period_calc_elements BIGINT,
    p_modif_final_peraca BIGINT,
    p_subject_grade_criteria BIGINT,
    p_final_grade_criteria BIGINT,
    p_area_grade_criteria BIGINT,
    p_student_wo_grades BIGINT,
    p_rounding_mode BIGINT,
    p_initial_grade NUMERIC,
    p_max_recovery_grade NUMERIC,
    p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_escala_actual    BIGINT;
    v_fk_tescala       BIGINT;
    v_formato_nombre   VARCHAR;
    v_formato_max      NUMERIC;
    v_initial_pct      NUMERIC;
    v_max_recovery_pct NUMERIC;
BEGIN
    PERFORM academico_test.fn_criterio_eval_validar(p_pk_periodo, p_grading_format, p_grading_scale,
        p_set_grading_scale, p_period_calc_elements, p_modif_final_peraca, p_subject_grade_criteria,
        p_final_grade_criteria, p_area_grade_criteria, p_student_wo_grades, p_rounding_mode);

    -- Con p_set_grading_scale y p_grading_scale NULL la escala se limpia.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        SELECT tv.FK_TESCALA INTO v_fk_tescala
          FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TESCALA t ON t.PK_TESCALA = tv.FK_TESCALA AND t.ACTIVE = TRUE
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale AND tv.ACTIVE = TRUE;
    END IF;

    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    IF p_initial_grade IS NOT NULL OR p_max_recovery_grade IS NOT NULL THEN
        SELECT lv.NOMBRE INTO v_formato_nombre
          FROM academico_test.TCRITERIO_EVALUACION ce
          JOIN academico_test.TLISTA_VALOR lv
            ON lv.PK_LISTA_VALOR = COALESCE(p_grading_format, ce.FK_TLV_FORMATO_CALIFICACION)
         WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_periodo AND ce.ACTIVE = TRUE;
        v_formato_max := CASE UPPER(TRIM(COALESCE(v_formato_nombre, '')))
                              WHEN 'DE CERO A CINCO' THEN 5
                              WHEN 'DE CERO A DIEZ' THEN 10
                              ELSE 100
                          END;
        v_initial_pct      := ROUND(p_initial_grade / v_formato_max * 100, 2);
        v_max_recovery_pct := ROUND(p_max_recovery_grade / v_formato_max * 100, 2);
    END IF;

    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA = CASE WHEN p_set_grading_scale THEN v_fk_tescala ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_MODIF_FINAL_PERACA = COALESCE(p_modif_final_peraca, FK_TLV_MODIF_FINAL_PERACA),
        FK_TLV_CRITERIO_ASIGNATURA = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
        FK_TLV_CRITERIO_FINAL = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        FK_TLV_MODO_REDONDEAR = COALESCE(p_rounding_mode, FK_TLV_MODO_REDONDEAR),
        PORCENTAJE_INICIAL_CALIF = COALESCE(v_initial_pct, PORCENTAJE_INICIAL_CALIF),
        PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(v_max_recovery_pct, PORCENTAJE_MAXIMO_RECUPERACION),
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL AND v_fk_tescala IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, v_fk_tescala, p_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_actualizar_interno(BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR)
    IS 'INTERNO: valida y actualiza los criterios de evaluacion activos de un periodo academico; los NULL conservan el valor y un cambio de escala se propaga con fn_escala_propagar. Lo usa fn_criterio_eval_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_obtener_interno(p_pk_periodo BIGINT)
RETURNS TABLE (
    academic_period_id BIGINT,
    grading_format BIGINT, grading_format_name VARCHAR,
    grading_scale BIGINT, grading_scale_name VARCHAR,
    period_calculation_elements BIGINT, period_calculation_elements_name VARCHAR,
    subject_grade_criteria BIGINT, subject_grade_criteria_name VARCHAR,
    final_grade_criteria BIGINT, final_grade_criteria_name VARCHAR,
    area_grade_criteria BIGINT, area_grade_criteria_name VARCHAR,
    student_without_grades_performance BIGINT, student_without_grades_performance_name VARCHAR,
    rounding_mode BIGINT, rounding_mode_name VARCHAR,
    initial_grade NUMERIC,
    decimal_places NUMERIC,
    final_grade_editable BIGINT, final_grade_editable_name VARCHAR,
    max_recovery_grade NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT ce.PK_TCRITERIO_EVALUACION,
           ce.FK_TLV_FORMATO_CALIFICACION, formato.NOMBRE,
           ce.FK_TESCALA, escala.NOMBRE,
           ce.FK_TLV_ELEMENTO_DEF, elemento.NOMBRE,
           ce.FK_TLV_CRITERIO_ASIGNATURA, criterio_asignatura.NOMBRE,
           ce.FK_TLV_CRITERIO_FINAL, criterio_final.NOMBRE,
           ce.FK_TLV_CRITERIO_AREA, criterio_area.NOMBRE,
           ce.FK_TLV_DESEMPENO_SIN_CALIF, desempeno.NOMBRE,
           ce.FK_TLV_MODO_REDONDEAR, modo_redondear.NOMBRE,
           round(ce.PORCENTAJE_INICIAL_CALIF / 100
                 * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2),
           ce.NUMERO_DECIMALES,
           ce.FK_TLV_MODIF_FINAL_PERACA, modif_final.NOMBRE,
           round(ce.PORCENTAJE_MAXIMO_RECUPERACION / 100
                 * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2)
      FROM academico_test.TCRITERIO_EVALUACION ce
      LEFT JOIN academico_test.TLISTA_VALOR formato             ON formato.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
      LEFT JOIN academico_test.TESCALA escala                   ON escala.PK_TESCALA = ce.FK_TESCALA
      LEFT JOIN academico_test.TLISTA_VALOR elemento            ON elemento.PK_LISTA_VALOR = ce.FK_TLV_ELEMENTO_DEF
      LEFT JOIN academico_test.TLISTA_VALOR criterio_asignatura ON criterio_asignatura.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_ASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR criterio_final      ON criterio_final.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL
      LEFT JOIN academico_test.TLISTA_VALOR criterio_area       ON criterio_area.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_AREA
      LEFT JOIN academico_test.TLISTA_VALOR desempeno           ON desempeno.PK_LISTA_VALOR = ce.FK_TLV_DESEMPENO_SIN_CALIF
      LEFT JOIN academico_test.TLISTA_VALOR modo_redondear      ON modo_redondear.PK_LISTA_VALOR = ce.FK_TLV_MODO_REDONDEAR
      LEFT JOIN academico_test.TLISTA_VALOR modif_final         ON modif_final.PK_LISTA_VALOR = ce.FK_TLV_MODIF_FINAL_PERACA
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_periodo AND ce.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_obtener_interno(BIGINT)
    IS 'INTERNO: criterios de evaluacion activos de un periodo academico con el nombre de cada catalogo y las notas en la escala del formato, sin alcance. Lo usa fn_criterio_eval_obtener.';
