-- ===========================================================================
-- V42.3 -- Escalas de valoracion: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V78/V135. Cada
-- una: existencia (P0002) -> gate con el alcance del periodo academico ->
-- fn_audit_declarar si escribe -> delegar en V42.2. Firmas sin cambios.
-- POR QUE AQUI: capa 3 del modulo (V42.1 / V42.2 / V42.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V42.1, V42.2.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Gate por sede+jornada del periodo: coordinadores y docentes escriben escalas de su sede.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_guardar_bulk(
    p_academic_period_id bigint, p_teaching_level_ids bigint[], p_scales jsonb, p_pk_usuario_solicitante bigint
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT := academico_test.fn_periodo_establecimiento(p_academic_period_id);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Registro de valoraciones en la escala de valoración del periodo %s',
            COALESCE((SELECT NOMBRE FROM academico_test.TPERIODO_ACADEMICO
                       WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id), p_academic_period_id::TEXT)),
        v_est);
    RETURN academico_test.fn_escala_guardar_bulk_interno(
        p_academic_period_id, p_teaching_level_ids, p_scales, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_guardar_bulk(BIGINT, BIGINT[], JSONB, BIGINT)
    IS 'POST /escalas. Gate EDITAR sobre PERIODOS_ACADEMICOS con el alcance del periodo academico; delega en fn_escala_guardar_bulk_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_listar(
    p_academic_period_id bigint,
    p_filtro             text DEFAULT NULL::text,
    p_pk_usuario          bigint DEFAULT NULL::bigint,
    p_teaching_level_id  bigint DEFAULT NULL::bigint,
    p_sort_by            text DEFAULT NULL::text,
    p_sort_dir            text DEFAULT NULL::text,
    p_tipo                text DEFAULT NULL::text
)
RETURNS TABLE(id bigint, nombre character varying, abreviacion character varying, tipo character varying, tipo_name character varying, iconografia character varying, teaching_level_id bigint, teaching_level_name character varying, nota_minima numeric, nota_maxima numeric, nota_equivalente numeric, escala_id bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todas las filas son del mismo periodo academico: el alcance se mira una vez.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_academic_period_id) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_escala_listar_interno(
        p_academic_period_id, p_filtro, p_teaching_level_id, p_sort_by, p_sort_dir, p_tipo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_listar(BIGINT, TEXT, BIGINT, BIGINT, TEXT, TEXT, TEXT)
    IS 'POST /escalas/:PERIODO_ACADEMICO_ID y /escalas/reporte. Vacio si el usuario no alcanza el periodo academico; delega en fn_escala_listar_interno.';

-- p_pk es una banda (TESCALA_VALORACION), no una escala.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_periodo_id BIGINT; v_est BIGINT; v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_escala_valoracion_validar_existe(p_pk);
    PERFORM academico_test.fn_escala_valoracion_validar_activa(p_pk);
    SELECT ne.FK_PERIODO_ACADEMICO, academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
      INTO v_periodo_id, v_est
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA AND ne.ACTIVE = TRUE
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    SELECT tv.NOMBRE INTO v_nombre
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la banda de valoración %s', COALESCE(v_nombre, p_pk::TEXT)), v_est);
    RETURN academico_test.fn_escala_valoracion_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_eliminar(BIGINT, BIGINT)
    IS 'PUT /escalas/:ID. Baja de una banda. Gate ELIMINAR con el alcance del periodo academico; delega en fn_escala_valoracion_eliminar_interno.';

-- Cada id se gatea con su propio alcance dentro de fn_escala_eliminar.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_escala_eliminar(v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_escala_valoracion_bulk_delete(BIGINT[], BIGINT)
    IS 'POST /escalas/valoraciones/bulk-delete. Un resultado por banda; los errores no cortan el lote.';

-- Sin wrapper unitario por escala: cada id se valida y gatea aqui con el alcance de su periodo.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_bulk_delete(p_escala_ids bigint[], p_pk_usuario_solicitante bigint)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_est BIGINT; v_periodo_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_escala_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_escala_ids LOOP
        BEGIN
            PERFORM academico_test.fn_escala_validar_existe(v_id);
            PERFORM academico_test.fn_escala_validar_activa(v_id);
            v_periodo_id := NULL; v_est := NULL;
            SELECT ne.FK_PERIODO_ACADEMICO, academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
              INTO v_periodo_id, v_est
              FROM academico_test.TNIVEL_ESCALA ne
             WHERE ne.FK_TESCALA = v_id AND ne.ACTIVE = TRUE
             LIMIT 1;
            PERFORM academico_test.fn_periodo_gate_escritura(
                p_pk_usuario_solicitante, v_est,
                academico_test.fn_periodo_sede(v_periodo_id),
                academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
            PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
                format('Eliminación de la escala %s',
                    (SELECT NOMBRE FROM academico_test.TESCALA WHERE PK_TESCALA = v_id)), v_est);
            PERFORM academico_test.fn_escala_cascada_eliminar_interno(v_id, p_pk_usuario_solicitante::VARCHAR);
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

COMMENT ON FUNCTION academico_test.fn_escala_bulk_delete(BIGINT[], BIGINT)
    IS 'Sin endpoint propio. Baja de escalas completas por id; un resultado por escala, los errores no cortan el lote. Delega en fn_escala_cascada_eliminar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_soft_delete(
    p_academic_period_id bigint, p_teaching_level_id bigint, p_pk_usuario_solicitante bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_escala BIGINT; v_est BIGINT; v_nivel_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_escala_validar_nivel_tiene_escala(p_academic_period_id, p_teaching_level_id);
    v_est := academico_test.fn_periodo_establecimiento(p_academic_period_id);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'ELIMINAR');
    SELECT ne.FK_TESCALA INTO v_escala FROM academico_test.TNIVEL_ESCALA ne
     WHERE ne.FK_PERIODO_ACADEMICO = p_academic_period_id
       AND ne.FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ne.ACTIVE = TRUE;
    SELECT NOMBRE INTO v_nivel_nombre
      FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_teaching_level_id;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la escala de valoración del nivel %s', COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT)),
        v_est);
    RETURN academico_test.fn_escala_cascada_eliminar_interno(
        v_escala, p_pk_usuario_solicitante::VARCHAR, p_academic_period_id, p_teaching_level_id);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_nivel_soft_delete(BIGINT, BIGINT, BIGINT)
    IS 'PUT /periodos/:PERIODO_ID/niveles/:NIVEL_ID/escala. Gate ELIMINAR con el alcance del periodo academico; delega en fn_escala_cascada_eliminar_interno.';

-- El gate inicial solo exige capability y establecimiento; cada nivel se gatea con sede+jornada en fn_escala_nivel_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_bulk_soft_delete(
    p_academic_period_id bigint, p_teaching_level_ids bigint[], p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id),
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'ELIMINAR');
    IF p_teaching_level_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_teaching_level_ids LOOP
        BEGIN
            PERFORM academico_test.fn_escala_nivel_soft_delete(
                p_academic_period_id, v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_escala_nivel_bulk_soft_delete(BIGINT, BIGINT[], BIGINT)
    IS 'POST /escalas/bulk-delete. Un resultado por nivel; los errores no cortan el lote. Delega por nivel en fn_escala_nivel_soft_delete.';
