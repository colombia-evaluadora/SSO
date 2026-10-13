-- ===========================================================================
-- V38.3 -- Criterios de promocion: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V76 (y fn_grade_config_*
-- de V43). Escritura: periodo informado y existente -> gate con el alcance del
-- periodo academico -> fn_audit_declarar -> delegar en V38.2. Lectura: filtro
-- de alcance. Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V38.1 / V38.2 / V38.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V38.1, V38.2.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar(
    p_fk_periodo bigint,
    p_fk_grado bigint DEFAULT NULL::bigint,
    p_nodo_curricular academico_test.nodo_curricular DEFAULT NULL::character varying,
    p_cantidad_nivelar numeric DEFAULT NULL::numeric,
    p_asignatura_obligatoria academico_test.bool_sn DEFAULT NULL::character varying,
    p_aprobacion_promedio academico_test.bool_sn DEFAULT NULL::character varying,
    p_desempenho_min_general numeric DEFAULT NULL::numeric,
    p_desempenho_minimo numeric DEFAULT NULL::numeric,
    p_max_asig_promedio numeric DEFAULT NULL::numeric,
    p_minimo_inasistencias numeric DEFAULT NULL::numeric,
    p_max_asig_nivelar_prom numeric DEFAULT NULL::numeric,
    p_obligatorias bigint[] DEFAULT NULL::bigint[],
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT; v_nombre_grado VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_criterio_prom_validar_periodo_informado(p_fk_periodo);
    PERFORM academico_test.fn_criterio_prom_validar_periodo_existe(p_fk_periodo);
    v_est := academico_test.fn_periodo_establecimiento(p_fk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'EDITAR');
    IF p_fk_grado IS NOT NULL THEN
        SELECT NOMBRE INTO v_nombre_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        CASE WHEN p_fk_grado IS NULL
             THEN 'Configuración del criterio de promoción general del periodo'
             ELSE format('Configuración del criterio de promoción del grado %s', v_nombre_grado)
        END, v_est);
    RETURN academico_test.fn_criterio_prom_guardar_interno(p_fk_periodo, p_fk_grado, p_nodo_curricular,
        p_cantidad_nivelar, p_asignatura_obligatoria, p_aprobacion_promedio, p_desempenho_min_general,
        p_desempenho_minimo, p_max_asig_promedio, p_minimo_inasistencias, p_max_asig_nivelar_prom,
        p_obligatorias, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_prom_guardar(BIGINT, BIGINT, academico_test.nodo_curricular, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, BIGINT[], BIGINT)
    IS 'PUT /periodos/:ID/criterio-promocion. Gate EDITAR con el alcance del periodo academico; delega en fn_criterio_prom_guardar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_obtener(
    p_fk_periodo BIGINT DEFAULT NULL,
    p_fk_grado   BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, academic_period_id BIGINT, grade_id BIGINT, curriculum_node academico_test.nodo_curricular,
    max_failed_recovery NUMERIC, asignatura_obligatoria academico_test.bool_sn,
    apply_average_approval academico_test.bool_sn, base_percentage NUMERIC,
    minimum_subject_percentage NUMERIC, max_failed_for_average NUMERIC,
    absence_percentage NUMERIC, max_leveled_subjects NUMERIC, mandatory_subjects JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT c.*
      FROM academico_test.fn_criterio_prom_obtener_interno(p_fk_periodo, p_fk_grado) c
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, c.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_prom_obtener(BIGINT, BIGINT, BIGINT)
    IS 'GET /periodos/:ID/criterio-promocion. Vacio si no hay criterio o el usuario no alcanza su periodo academico; delega en fn_criterio_prom_obtener_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_nodo_curricular_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (key TEXT, label TEXT)
LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES ('AS', 'Asignatura'), ('AR', 'Area')) AS t(key, label);
$$;

COMMENT ON FUNCTION academico_test.fn_nodo_curricular_listar(BIGINT)
    IS 'GET /catalogos/nodos-curriculares. Catalogo fijo de nodo_curricular (AS asignatura, AR area).';
