-- ===========================================================================
-- V40.4 -- Areas, asignaturas y enfasis: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V77 y V135. Cada una:
-- existencia (P0002) -> gate con el alcance del periodo academico (area,
-- asignatura) o de la sede (enfasis) -> fn_audit_declarar si escribe ->
-- delegar en V40.3. Lecturas: alcance en el wrapper (vacio si no). Cambian de
-- firma fn_enfasis_resolver y fn_especialidad_enfasis_listar (periodo en vez
-- de establecimiento); V77 actualiza sus filas de public.query. Borra la
-- sobrecarga de 5 parametros de fn_enfasis_actualizar (venia de V40.1).
-- POR QUE AQUI: capa 3 del modulo (V40.2 / V40.3 / V40.4).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V40.2, V40.3.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_enfasis_actualizar(
    BIGINT, CHARACTER VARYING, CHARACTER VARYING, BIGINT, BIGINT);

-- --------------------------------------------------------------------- area

CREATE OR REPLACE FUNCTION academico_test.fn_area_crear(p_fk_periodo bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT := academico_test.fn_periodo_establecimiento(p_fk_periodo);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del área %s', p_nombre_interno), v_est);
    RETURN academico_test.fn_area_crear_interno(p_fk_periodo, p_fk_area_asignatura, p_nombre_interno,
        p_abreviacion, p_orden_reportes, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, NUMERIC, BIGINT)
    IS 'POST /areas. Gate CREAR sobre PERIODOS_ACADEMICOS con el alcance del periodo academico; delega en fn_area_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_actualizar(p_pk bigint, p_fk_area_asignatura bigint DEFAULT NULL::bigint, p_nombre_interno character varying DEFAULT NULL::character varying, p_abreviacion character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT NULL::numeric, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_area_validar_existe_activa(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_nombre
      FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del área %s', COALESCE(p_nombre_interno, v_nombre)), v_est);
    RETURN academico_test.fn_area_actualizar_interno(p_pk, p_fk_area_asignatura, p_nombre_interno,
        p_abreviacion, p_orden_reportes, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, NUMERIC, BIGINT)
    IS 'PUT /areas/:ID. Gate EDITAR con el alcance del periodo academico del area; delega en fn_area_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_area_validar_existe_activa(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_nombre
      FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del área %s', v_nombre), v_est);
    RETURN academico_test.fn_area_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_soft_delete(BIGINT, BIGINT)
    IS 'PUT /areas/eliminar/:ID. Gate ELIMINAR con el alcance del periodo academico del area; delega en fn_area_eliminar_interno.';

-- Gate grueso (capability, accion por defecto EDITAR); cada id se gatea con
-- su propio alcance dentro de fn_area_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_area_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, NULL, NULL, NULL, 'ELIMINAR');
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_area_soft_delete(v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_area_bulk_delete(BIGINT[], BIGINT)
    IS 'Sin fila en public.query. Baja logica de varias areas: un resultado por id; los errores no cortan el lote.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_listar(
    p_fk_periodo BIGINT, p_nombre_interno TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_general_id BIGINT, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_area_listar_interno(
        p_fk_periodo, p_nombre_interno, p_page_index, p_page_size, p_sort_by, p_sort_dir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /areas/query. Vacio si el usuario no alcanza el periodo academico; delega en fn_area_listar_interno.';

-- Catalogo global de areas/asignaturas generales: no tiene alcance que filtrar.
CREATE OR REPLACE FUNCTION academico_test.fn_area_asignatura_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, especialidad_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT PK_TAREA_ASIGNATURA, NOMBRE, FK_TESPECIALIDAD
      FROM academico_test.TAREA_ASIGNATURA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_area_asignatura_listar(BIGINT)
    IS 'GET /areas/general y GET /catalogos/areas-asignaturas. Catalogo global activo de TAREA_ASIGNATURA; p_pk_usuario_solicitante no filtra.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_areas_asignaturas_listar(
    p_fk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (area_id BIGINT, area_nombre VARCHAR, asignaturas JSONB)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, p_fk_periodo) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_periodo_areas_asignaturas_listar_interno(p_fk_periodo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_areas_asignaturas_listar(BIGINT, BIGINT)
    IS 'GET /periodos/:ID/areas/asignaturas. Vacio si el usuario no alcanza el periodo academico; delega en fn_periodo_areas_asignaturas_listar_interno.';

-- --------------------------------------------------------------- asignatura

-- La asignatura no tiene sede ni jornada propias: hereda las del periodo de su area.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear(p_fk_area bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_fk_enfasis bigint DEFAULT 2, p_color character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_est BIGINT;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación de la asignatura %s', p_nombre_interno), v_est);
    RETURN academico_test.fn_subject_crear_interno(p_fk_area, p_fk_area_asignatura, p_nombre_interno,
        p_abreviacion, p_fk_enfasis, p_color, p_orden_reportes, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, NUMERIC, BIGINT)
    IS 'POST /areas/:FK_AREA/asignaturas. Gate CREAR con el alcance del periodo academico del area; delega en fn_subject_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_actualizar(p_pk bigint, p_fk_area_asignatura bigint DEFAULT NULL::bigint, p_nombre_interno character varying DEFAULT NULL::character varying, p_abreviacion character varying DEFAULT NULL::character varying, p_fk_enfasis bigint DEFAULT NULL::bigint, p_color character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT NULL::numeric, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_subject_validar_existe_activa(p_pk);
    SELECT a.FK_TPERIODO_ACADEMICO, s.NOMBRE INTO v_periodo, v_nombre
      FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
     WHERE s.PK_TASIGNATURA = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización de la asignatura %s', COALESCE(p_nombre_interno, v_nombre)), v_est);
    RETURN academico_test.fn_subject_actualizar_interno(p_pk, p_fk_area_asignatura, p_nombre_interno,
        p_abreviacion, p_fk_enfasis, p_color, p_orden_reportes, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, NUMERIC, BIGINT)
    IS 'PUT /areas/asignaturas/:SUBJECT_ID. Gate EDITAR con el alcance del periodo academico del area; delega en fn_subject_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_subject_validar_existe_activa(p_pk);
    SELECT a.FK_TPERIODO_ACADEMICO, s.NOMBRE INTO v_periodo, v_nombre
      FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
     WHERE s.PK_TASIGNATURA = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la asignatura %s', v_nombre), v_est);
    RETURN academico_test.fn_subject_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_soft_delete(BIGINT, BIGINT)
    IS 'PUT /areas/asignaturas/eliminar/:SUBJECT_ID. Gate ELIMINAR con el alcance del periodo academico del area; delega en fn_subject_eliminar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk(p_fk_area bigint, p_asignaturas jsonb, p_pk_usuario_solicitante bigint)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'EDITAR');
    PERFORM academico_test.fn_subject_validar_area_activa(p_fk_area);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_nombre
      FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización de las asignaturas del área %s', v_nombre), v_est);
    RETURN academico_test.fn_subject_guardar_bulk_interno(p_fk_area, p_asignaturas,
        p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_guardar_bulk(BIGINT, JSONB, BIGINT)
    IS 'PUT /areas/:ID/asignaturas. Gate EDITAR con el alcance del periodo academico del area; delega en fn_subject_guardar_bulk_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar(p_fk_area bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS TABLE(id bigint, abreviacion character varying, nombre_interno character varying,
              asignatura_general_id bigint, enfasis_id bigint, enfasis_nombre character varying,
              color character varying, orden_reportes numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todas las filas son de la misma area: el alcance se mira una vez.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
           (SELECT FK_TPERIODO_ACADEMICO FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area)) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_subject_listar_interno(p_fk_area);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_listar(BIGINT, BIGINT)
    IS 'GET /areas/:ID/asignaturas. Vacio si el usuario no alcanza el periodo academico del area; delega en fn_subject_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_periodo_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_id BIGINT, area_nombre VARCHAR,
               asignatura_general_id BIGINT, enfasis_id BIGINT, enfasis_nombre VARCHAR,
               color VARCHAR, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_subject_periodo_listar_interno(
        p_fk_periodo, p_filtro, p_page_index, p_page_size, p_sort_by, p_sort_dir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_periodo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /areas/asignaturas. Vacio si el usuario no alcanza el periodo academico; delega en fn_subject_periodo_listar_interno.';

-- ------------------------------------------------------------------ enfasis

-- El enfasis es de una sede: el gate usa esa sede. Un usuario de nivel 3
-- necesita sede y jornada; para un enfasis (sin jornada) vale cualquier
-- jornada de la sede que el usuario alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_gate_escritura(
    p_pk_usuario BIGINT, p_fk_sede BIGINT, p_accion VARCHAR
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario,
        (SELECT FK_TESTABLECIMIENTO FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede),
        p_fk_sede,
        (SELECT sj.jornada_id FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario) sj
          WHERE sj.sede_id = p_fk_sede ORDER BY sj.jornada_id LIMIT 1),
        p_accion);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_gate_escritura(BIGINT, BIGINT, VARCHAR)
    IS 'Gate de escritura de un enfasis existente: fn_periodo_gate_escritura con su sede y, para nivel 3, cualquier jornada de esa sede que el usuario alcance.';

-- El primer parametro paso de establecimiento a periodo academico: el enfasis
-- nace en la sede del periodo y el gate usa su sede y jornada.
DROP FUNCTION IF EXISTS academico_test.fn_enfasis_resolver(BIGINT, VARCHAR, VARCHAR, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_resolver(
    p_fk_periodo BIGINT,
    p_nombre VARCHAR,
    p_codigo VARCHAR DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_enfasis_validar_periodo_activo(p_fk_periodo);
    v_est := academico_test.fn_periodo_establecimiento(p_fk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del énfasis %s', p_nombre), v_est);
    RETURN academico_test.fn_enfasis_resolver_interno(academico_test.fn_periodo_sede(p_fk_periodo),
        p_nombre, p_codigo, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_resolver(BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'POST /enfasis. Gate EDITAR con la sede y jornada del periodo academico; devuelve o crea el enfasis de esa sede con fn_enfasis_resolver_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(p_pk bigint, p_nombre character varying DEFAULT NULL::character varying, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_sede BIGINT; v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_enfasis_validar_existe_activo(p_pk);
    SELECT FK_TSEDE, FK_TESTABLECIMIENTO INTO v_sede, v_est
      FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
    PERFORM academico_test.fn_enfasis_gate_escritura(p_pk_usuario_solicitante, v_sede, 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del énfasis %s', p_nombre), v_est);
    RETURN academico_test.fn_enfasis_actualizar_interno(p_pk, p_nombre, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_actualizar(BIGINT, VARCHAR, BIGINT)
    IS 'PUT /enfasis/:ID. Gate EDITAR con la sede del enfasis; delega en fn_enfasis_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_sede BIGINT; v_est BIGINT; v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_enfasis_validar_existe_activo(p_pk);
    SELECT FK_TSEDE, FK_TESTABLECIMIENTO, NOMBRE INTO v_sede, v_est, v_nombre
      FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
    PERFORM academico_test.fn_enfasis_gate_escritura(p_pk_usuario_solicitante, v_sede, 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del énfasis %s', v_nombre), v_est);
    RETURN academico_test.fn_enfasis_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_soft_delete(BIGINT, BIGINT)
    IS 'PUT /enfasis/eliminar/:ID. Gate ELIMINAR con la sede del enfasis; delega en fn_enfasis_eliminar_interno.';

-- El primer parametro paso de establecimiento a periodo academico. Las
-- especialidades son globales; los enfasis de la sede del periodo solo salen
-- si el usuario alcanza ese periodo.
DROP FUNCTION IF EXISTS academico_test.fn_especialidad_enfasis_listar(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_especialidad_enfasis_listar(
    p_fk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, codigo VARCHAR, origen TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT * FROM academico_test.fn_especialidad_enfasis_listar_interno(
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, p_fk_periodo) IS TRUE);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_especialidad_enfasis_listar(BIGINT, BIGINT)
    IS 'GET /areas/:ID/especialidades (:ID = periodo academico). Especialidades globales siempre; enfasis de la sede del periodo solo si el usuario alcanza el periodo. Delega en fn_especialidad_enfasis_listar_interno.';

-- --------------------------------------------------------------- reporte
-- Una fila por area + asignatura de todo el periodo (antes V188). La pantalla
-- edita areas y asignaturas por separado; el export las junta.
CREATE OR REPLACE FUNCTION academico_test.fn_area_subject_reporte_listar(
    p_fk_periodo         BIGINT,
    p_fk_area            BIGINT[] DEFAULT NULL,
    p_fk_asignatura      BIGINT[] DEFAULT NULL,
    p_fk_especialidad    BIGINT[] DEFAULT NULL,
    p_incluir_inactivos  BOOLEAN  DEFAULT FALSE,
    p_pk_usuario         BIGINT   DEFAULT NULL,
    p_page_index         INT      DEFAULT 0,
    p_page_size          INT      DEFAULT 10
)
RETURNS TABLE (
    area_id BIGINT, area_general_name VARCHAR, area_nombre_interno VARCHAR, area_abreviacion VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, asignatura_abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    orden_reportes NUMERIC, color VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    -- Los mismos nucleos que la pantalla (areas del periodo y asignaturas de
    -- cada area); LEFT para que un area sin asignaturas salga igual.
    SELECT a.id, ta.NOMBRE, a.nombre_interno, a.codigo,
           s.id, s.nombre_interno, s.abreviacion,
           s.enfasis_id, s.enfasis_nombre,
           s.orden_reportes, s.color,
           count(*) OVER()::BIGINT
      FROM academico_test.fn_area_listar_interno(p_fk_periodo, NULL, 0, 0, NULL, NULL, p_incluir_inactivos) a
      JOIN academico_test.TAREA_ASIGNATURA ta ON ta.PK_TAREA_ASIGNATURA = a.area_general_id
 LEFT JOIN LATERAL academico_test.fn_subject_listar_interno(a.id, p_incluir_inactivos) s ON TRUE
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS TRUE
       AND (p_fk_area         IS NULL OR CARDINALITY(p_fk_area)         = 0 OR a.id         = ANY(p_fk_area))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.id         = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR s.enfasis_id = ANY(p_fk_especialidad))
     ORDER BY a.orden_reportes, a.nombre_interno, s.orden_reportes, s.nombre_interno
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

COMMENT ON FUNCTION academico_test.fn_area_subject_reporte_listar(BIGINT, BIGINT[], BIGINT[], BIGINT[], BOOLEAN, BIGINT, INT, INT)
    IS 'POST /areas/reporte. Areas con sus asignaturas de todo el periodo, filtros opcionales; vacio si el usuario no alcanza el periodo.';
