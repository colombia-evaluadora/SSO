-- ===========================================================================
-- V39.3 -- Periodo de evaluacion: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V76. Cada una:
-- existencia (P0002) -> estado (22023) -> gate con el alcance del periodo
-- academico padre -> fn_audit_declarar si escribe -> delegar en V39.2.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V39.1 / V39.2 / V39.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V39.1, V39.2.
-- ===========================================================================

SET search_path TO academico_test, public;

-- El periodo de evaluacion no tiene sede ni jornada propias: hereda las del periodo academico.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_crear(
    p_fk_periodo     BIGINT,
    p_codigo         VARCHAR(30),
    p_nombre         VARCHAR(130),
    p_abreviacion    VARCHAR(30),
    p_fecha_inicio   DATE,
    p_fecha_fin      DATE,
    p_fk_estado      BIGINT,
    p_porcentaje     NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT := academico_test.fn_periodo_establecimiento(p_fk_periodo);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PERIODOS_ACADEMICOS', 'CREAR', v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo));
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del periodo de evaluación %s', p_nombre), v_est);
    RETURN academico_test.fn_periodo_eval_crear_interno(p_fk_periodo, p_codigo, p_nombre, p_abreviacion,
        p_fecha_inicio, p_fecha_fin, p_fk_estado, p_porcentaje, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_crear(BIGINT, VARCHAR, VARCHAR, VARCHAR, DATE, DATE, BIGINT, NUMERIC, BIGINT)
    IS 'POST /periodo-evaluacion. Gate CREAR sobre PERIODOS_ACADEMICOS con el alcance del periodo academico; delega en fn_periodo_eval_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_actualizar(
    p_pk bigint,
    p_codigo character varying DEFAULT NULL::character varying,
    p_nombre character varying DEFAULT NULL::character varying,
    p_abreviacion character varying DEFAULT NULL::character varying,
    p_fecha_inicio date DEFAULT NULL::date,
    p_fecha_fin date DEFAULT NULL::date,
    p_fk_estado bigint DEFAULT NULL::bigint,
    p_porcentaje numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_fk_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_eval_validar_existe(p_pk);
    PERFORM academico_test.fn_periodo_eval_validar_activo(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_fk_periodo, v_nombre
      FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_fk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_fk_periodo),
        academico_test.fn_periodo_jornada(v_fk_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del periodo de evaluación %s', COALESCE(p_nombre, v_nombre)), v_est);
    RETURN academico_test.fn_periodo_eval_actualizar_interno(p_pk, p_codigo, p_nombre, p_abreviacion,
        p_fecha_inicio, p_fecha_fin, p_fk_estado, p_porcentaje, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_actualizar(BIGINT, VARCHAR, VARCHAR, VARCHAR, DATE, DATE, BIGINT, NUMERIC, BIGINT)
    IS 'PUT /periodo-evaluacion/editar/:ID. Gate EDITAR con el alcance del periodo academico; delega en fn_periodo_eval_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_soft_delete(
    p_pk bigint,
    p_pk_usuario_solicitante bigint
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_fk_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_eval_validar_existe(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_fk_periodo, v_nombre
      FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_fk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_fk_periodo),
        academico_test.fn_periodo_jornada(v_fk_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del periodo de evaluación %s', v_nombre), v_est);
    RETURN academico_test.fn_periodo_eval_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_soft_delete(BIGINT, BIGINT)
    IS 'PUT /periodo-evaluacion/:ID. Gate ELIMINAR con el alcance del periodo academico; delega en fn_periodo_eval_eliminar_interno.';

-- Cada id se gatea con su propio alcance dentro de fn_periodo_eval_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'ELIMINAR');
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_periodo_eval_soft_delete(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_bulk_delete(BIGINT[], BIGINT)
    IS 'POST /periodo-evaluacion/bulk-delete. Un resultado por id; los errores no cortan el lote.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR, estado_name VARCHAR,
    academic_period_id BIGINT, sede_id BIGINT, sede_name VARCHAR, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todas las filas son del mismo periodo academico: el alcance se mira una vez.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_periodo_eval_listar_interno(
        p_fk_periodo, p_filtro, p_page_index, p_page_size, p_sort_by, p_sort_dir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /periodo-evaluacion/query y /periodo-evaluacion/reporte. Vacio si el usuario no alcanza el periodo academico; delega en fn_periodo_eval_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_detalle(
    p_pk BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR, estado_name VARCHAR,
    academic_period_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT d.*
      FROM academico_test.fn_periodo_eval_detalle_interno(p_pk) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, d.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_detalle(BIGINT, BIGINT)
    IS 'GET /periodo-evaluacion/detalle/:ID. Vacio si no existe o el usuario no alcanza su periodo academico.';
