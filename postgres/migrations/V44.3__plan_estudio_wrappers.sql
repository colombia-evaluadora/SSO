-- ===========================================================================
-- V44.3 -- Plan de estudio: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V80 y V135. Cada una:
-- existencia (P0002) -> estado -> gate con el alcance del periodo academico
-- del grado -> fn_audit_declarar si escribe -> delegar en V44.2. Lecturas:
-- vacio (o la fila de motivo, en restricciones) si no alcanza el periodo.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V44.1 / V44.2 / V44.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V44.1, V44.2.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(
    p_fk_grado             BIGINT,
    p_fk_asignatura        BIGINT,
    p_numero_hora          NUMERIC,
    p_influencia_area      NUMERIC,
    p_numero_credito       BIGINT,
    p_influye_desempeno    BOOLEAN,
    p_matricula_obligatoria BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif     BIGINT DEFAULT NULL,
    p_fk_criterio_nota     BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_grado_nom TEXT; v_est BIGINT;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_grado_nom
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Asignación de %s al plan de estudio del grado %s',
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura), v_grado_nom),
        v_est);
    RETURN academico_test.fn_plan_agregar_interno(p_fk_grado, p_fk_asignatura, p_numero_hora, p_influencia_area,
        p_numero_credito, p_influye_desempeno, p_matricula_obligatoria, p_aprobacion_obligatoria,
        p_fk_formato_calif, p_fk_criterio_nota, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_agregar(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, BOOLEAN, BOOLEAN, BOOLEAN, BIGINT, BIGINT, BIGINT)
    IS 'POST /grados/:ID/plan-asignaturas. Gate CREAR con el alcance del periodo del grado; delega en fn_plan_agregar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar(
    p_pk                   BIGINT,
    p_fk_asignatura        BIGINT  DEFAULT NULL,
    p_numero_hora          NUMERIC DEFAULT NULL,
    p_influencia_area      NUMERIC DEFAULT NULL,
    p_numero_credito       BIGINT  DEFAULT NULL,
    p_influye_desempeno    BOOLEAN DEFAULT NULL,
    p_matricula_obligatoria BOOLEAN DEFAULT NULL,
    p_aprobacion_obligatoria BOOLEAN DEFAULT NULL,
    p_fk_formato_calif     BIGINT  DEFAULT NULL,
    p_fk_criterio_nota     BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_grado_nom TEXT; v_asignatura_nom TEXT; v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_plan_validar_renglon_existe(p_pk);
    PERFORM academico_test.fn_plan_validar_renglon_activo(p_pk);
    SELECT g.FK_TPERIODO_ACADEMICO, g.NOMBRE, ta.NOMBRE INTO v_periodo, v_grado_nom, v_asignatura_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del plan de estudio: %s en %s',
            COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura),
                     v_asignatura_nom),
            v_grado_nom),
        v_est);
    RETURN academico_test.fn_plan_actualizar_interno(p_pk, p_fk_asignatura, p_numero_hora, p_influencia_area,
        p_numero_credito, p_influye_desempeno, p_matricula_obligatoria, p_aprobacion_obligatoria,
        p_fk_formato_calif, p_fk_criterio_nota, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_actualizar(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, BOOLEAN, BOOLEAN, BOOLEAN, BIGINT, BIGINT, BIGINT)
    IS 'PUT /plan-asignaturas/:ID. Gate EDITAR con el alcance del periodo del grado; delega en fn_plan_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_grado_nom TEXT; v_asignatura_nom TEXT; v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_plan_validar_renglon_existe(p_pk);
    SELECT g.FK_TPERIODO_ACADEMICO, g.NOMBRE, ta.NOMBRE INTO v_periodo, v_grado_nom, v_asignatura_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de %s del plan de estudio de %s', v_asignatura_nom, v_grado_nom), v_est);
    RETURN academico_test.fn_plan_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_eliminar(BIGINT, BIGINT)
    IS 'PUT /plan-asignaturas/:ID/eliminar. Gate ELIMINAR con el alcance del periodo del grado; delega en fn_plan_eliminar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_grado_nom TEXT; v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_plan_validar_existe_para_grado(p_fk_grado);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_grado_nom
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del plan de estudio completo del grado %s', v_grado_nom), v_est);
    RETURN academico_test.fn_plan_grado_eliminar_interno(p_fk_grado, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_soft_delete(BIGINT, BIGINT)
    IS 'PUT /grados/:ID/plan/eliminar. Gate ELIMINAR con el alcance del periodo del grado; delega en fn_plan_grado_eliminar_interno.';

-- Cada id se gatea con su propio alcance dentro de fn_plan_eliminar.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignatura_bulk_delete(
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
            PERFORM academico_test.fn_plan_eliminar(v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_plan_asignatura_bulk_delete(BIGINT[], BIGINT)
    IS 'POST /plan-asignaturas/bulk-delete. Un resultado por id; los errores no cortan el lote.';

DROP FUNCTION IF EXISTS academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR, enfasis_nombre VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todos los renglones son del mismo grado y por tanto del mismo periodo academico.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
           (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado)) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT l.codigo, l.asignatura_id, l.asignatura, l.enfasis_nombre, l.intensidad_horaria,
                        l.influencia_area, l.numero_creditos, l.influye_desempeno, l.matricula_obligatoria,
                        l.aprobacion_obligatoria, l.formato_calificacion, l.criterio_nota, l.personalizado,
                        l.total_count
      FROM academico_test.fn_plan_listar_interno(
        p_fk_grado, p_filtro, p_page_index, p_page_size, p_sort_by, p_sort_dir) l;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /grados/:ID/plan-asignaturas/query. Vacio si el usuario no alcanza el periodo del grado; delega en fn_plan_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC, numero_creditos BIGINT,
               influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
               formato_calificacion BIGINT, criterio_nota BIGINT, personalizado BOOLEAN, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT d.codigo, d.asignatura_id, d.asignatura, d.intensidad_horaria, d.influencia_area, d.numero_creditos,
           d.influye_desempeno, d.matricula_obligatoria, d.aprobacion_obligatoria,
           d.formato_calificacion, d.criterio_nota, d.personalizado, d.grado_id
      FROM academico_test.fn_plan_obtener_interno(p_pk) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, d.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_plan_obtener(BIGINT, BIGINT)
    IS 'GET /plan-asignaturas/:ID. Vacio si no existe o el usuario no alcanza el periodo de su grado.';

DROP FUNCTION IF EXISTS academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, area_id BIGINT, area_nombre VARCHAR, enfasis_nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT d.*
      FROM academico_test.fn_plan_asignaturas_disponibles_listar_interno(p_fk_grado, p_filtro) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
             (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
$$;

COMMENT ON FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT, BIGINT)
    IS 'GET /grados/:ID/plan-disponibles. Vacio si el usuario no alcanza el periodo del grado; delega en fn_plan_asignaturas_disponibles_listar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_plan_eliminar_restricciones(BIGINT, BIGINT);

-- Endpoint de chequeo: sin alcance responde con el motivo en vez de lanzar 42501.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar_restricciones(
    p_pk BIGINT,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (puede_eliminar BOOLEAN, puede_remover BOOLEAN, motivo TEXT, grado_conflicto TEXT)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_periodo BIGINT;
BEGIN
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE;
    -- Sin renglon activo el nucleo devuelve la fila de "no existe".
    IF FOUND AND NOT academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, v_periodo) THEN
        RETURN QUERY SELECT FALSE, FALSE,
            'No tiene permisos para consultar este renglón del plan de estudio'::TEXT, NULL::TEXT;
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_plan_eliminar_restricciones_interno(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_eliminar_restricciones(BIGINT, BIGINT)
    IS 'GET /plan-asignaturas/:ID/restricciones-eliminar. Fila de motivo si el usuario no alcanza el periodo del grado; delega en fn_plan_eliminar_restricciones_interno.';

-- --------------------------------------------------------------- reporte
-- Plan de estudio de todo el periodo, no de un grado (antes V186).
CREATE OR REPLACE FUNCTION academico_test.fn_plan_reporte_listar(
    p_fk_periodo      BIGINT,
    p_fk_grado        BIGINT[] DEFAULT NULL,
    p_fk_asignatura   BIGINT[] DEFAULT NULL,
    p_fk_especialidad BIGINT[] DEFAULT NULL,
    p_pk_usuario      BIGINT   DEFAULT NULL,
    p_page_index      INT      DEFAULT 0,
    p_page_size       INT      DEFAULT 10
)
RETURNS TABLE (
    id BIGINT, grado_id BIGINT, grado_name VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    intensidad_horaria NUMERIC, influencia_area NUMERIC,
    matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
    influye_desempeno BOOLEAN, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    -- Los mismos nucleos que la pantalla (grados del periodo y plan de cada
    -- grado): lo exportado coincide con lo que se ve.
    SELECT pl.codigo, g.id, g.nombre,
           pl.asignatura_id, pl.asignatura, pl.abreviacion,
           pl.especialidad_id, pl.enfasis_nombre,
           pl.intensidad_horaria, pl.influencia_area,
           pl.matricula_obligatoria, pl.aprobacion_obligatoria, pl.influye_desempeno,
           count(*) OVER()::BIGINT
      FROM academico_test.fn_grado_listar_interno(p_fk_periodo, NULL, 0, 0) g
     CROSS JOIN LATERAL academico_test.fn_plan_listar_interno(g.id, NULL, 0, 0) pl
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS TRUE
       AND (p_fk_grado        IS NULL OR CARDINALITY(p_fk_grado)        = 0 OR g.id               = ANY(p_fk_grado))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR pl.asignatura_id   = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR pl.especialidad_id = ANY(p_fk_especialidad))
     ORDER BY g.nombre, pl.asignatura
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

COMMENT ON FUNCTION academico_test.fn_plan_reporte_listar(BIGINT, BIGINT[], BIGINT[], BIGINT[], BIGINT, INT, INT)
    IS 'POST /plan-estudio/reporte. Renglones del plan de todos los grados del periodo, filtros opcionales; vacio si el usuario no alcanza el periodo.';
