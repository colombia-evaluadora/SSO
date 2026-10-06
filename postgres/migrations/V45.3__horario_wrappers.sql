-- ===========================================================================
-- V45.3 -- Horario: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V80 (y fn_grado_* de
-- V43). Escritura: existencia (P0002) -> estado (22023) -> gate con el
-- alcance del periodo academico del grado -> fn_audit_declarar -> delegar en
-- V45.2. Lecturas: vacio si el usuario no alcanza el periodo academico.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V45.1 / V45.2 / V45.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V45.1, V45.2.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar(
    p_fk_grado bigint,
    p_entries jsonb,
    p_pk_usuario_solicitante bigint
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_fk_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_horario_validar_grado_existe(p_fk_grado);
    PERFORM academico_test.fn_horario_validar_grado_activo(p_fk_grado);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_fk_periodo, v_nombre
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    v_est := academico_test.fn_periodo_establecimiento(v_fk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_fk_periodo),
        academico_test.fn_periodo_jornada(v_fk_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Configuración del horario del grado %s', v_nombre), v_est);
    RETURN academico_test.fn_horario_guardar_interno(p_fk_grado, p_entries, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_guardar(BIGINT, JSONB, BIGINT)
    IS 'POST /horarios. Gate EDITAR con el alcance del periodo academico del grado; delega en fn_horario_guardar_interno. Tambien la usa fn_grado_* al guardar el horario junto al grado.';

CREATE OR REPLACE FUNCTION academico_test.fn_horario_listar(
    p_fk_grado BIGINT,
    p_fk_grupo BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, grado_id BIGINT, grado VARCHAR, grupo_id BIGINT, grupo VARCHAR,
               plan_item_id BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               dia_id BIGINT, dia VARCHAR, dia_name VARCHAR, bloque NUMERIC)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todas las celdas son del mismo grado: el alcance se mira una vez.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
         (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado)) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_horario_listar_interno(p_fk_grado, p_fk_grupo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_listar(BIGINT, BIGINT, BIGINT)
    IS 'GET /horarios/:FK_GRADO. Vacio si el usuario no alcanza el periodo academico del grado; delega en fn_horario_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_horario_asignaturas(
    p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (plan_item_id BIGINT, nombre VARCHAR, bloques NUMERIC, color VARCHAR)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
         (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado)) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_horario_asignaturas_interno(p_fk_grado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_asignaturas(BIGINT, BIGINT)
    IS 'GET /horarios/asignaturas. Vacio si el usuario no alcanza el periodo academico del grado; delega en fn_horario_asignaturas_interno.';
