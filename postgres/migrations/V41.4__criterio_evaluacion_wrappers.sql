-- ===========================================================================
-- V41.4 -- Criterios de evaluacion: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V76. Escritura:
-- existencia (P0002) -> gate con el alcance del periodo academico ->
-- fn_audit_declarar -> delegar en V41.3. Lectura: filtro de alcance.
-- Las firmas no cambian: las filas de public.query siguen igual. Borra las
-- sobrecargas de 12 y 15 parametros de fn_criterio_eval_actualizar (venian de
-- V41.1): con casi todo DEFAULT vuelven ambigua (42725) una llamada corta.
-- POR QUE AQUI: capa 3 del modulo (V41.2 / V41.3 / V41.4).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V41.2, V41.3.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, NUMERIC, BIGINT);

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, NUMERIC, BIGINT, NUMERIC, BIGINT, NUMERIC);

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_modif_final_peraca bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode bigint DEFAULT NULL::bigint,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_max_recovery_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT; v_periodo_nombre VARCHAR;
BEGIN
    PERFORM academico_test.fn_criterio_eval_validar_existe(p_pk_periodo);
    v_est := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_pk_periodo),
        academico_test.fn_periodo_jornada(p_pk_periodo), 'EDITAR');
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre), v_est);
    RETURN academico_test.fn_criterio_eval_actualizar_interno(p_pk_periodo, p_grading_format,
        p_grading_scale, p_set_grading_scale, p_period_calc_elements, p_modif_final_peraca,
        p_subject_grade_criteria, p_final_grade_criteria, p_area_grade_criteria, p_student_wo_grades,
        p_rounding_mode, p_initial_grade, p_max_recovery_grade, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_actualizar(BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT)
    IS 'PUT /periodos/:ID/criterio-evaluacion. Gate EDITAR con el alcance del periodo academico; delega en fn_criterio_eval_actualizar_interno.';

-- DROP: servidores viejos la tienen con otras columnas de retorno y CREATE OR REPLACE no las cambia.
DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_obtener(
    p_pk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
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
    SELECT c.*
      FROM academico_test.fn_criterio_eval_obtener_interno(p_pk_periodo) c
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, c.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT)
    IS 'GET /periodos/:ID/criterio-evaluacion. Vacio si no hay criterio activo o el usuario no alcanza el periodo academico; delega en fn_criterio_eval_obtener_interno.';
