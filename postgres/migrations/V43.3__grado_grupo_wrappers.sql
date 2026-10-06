-- ===========================================================================
-- V43.3 -- Grados y grupos: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V79 y V135. Cada una:
-- existencia (P0002) -> estado -> gate con el alcance del periodo academico
-- (el grupo, con su propia jornada) -> fn_audit_declarar si escribe -> delegar
-- en V43.2. Lecturas: vacio si el usuario no alcanza el periodo.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V43.1 / V43.2 / V43.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V43.1, V43.2; en
-- ejecucion V38.3 (criterio de promocion) y V45.3 (horario) para grade-config.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------- grado

CREATE OR REPLACE FUNCTION academico_test.fn_grado_crear(
    p_fk_periodo BIGINT,
    p_fk_nivel BIGINT,
    p_nombre VARCHAR,
    p_fk_grado_siguiente BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT := academico_test.fn_periodo_establecimiento(p_fk_periodo); v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'CREAR');
    SELECT r.nombre INTO v_nombre FROM academico_test.fn_grado_catalogo_resolver(p_nombre) r;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del grado %s en la sede %s', COALESCE(v_nombre, p_nombre),
            (SELECT s.NOMBRE FROM academico_test.TSEDE s WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(p_fk_periodo))),
        v_est);
    RETURN academico_test.fn_grado_crear_interno(p_fk_periodo, p_fk_nivel, p_nombre, p_fk_grado_siguiente,
        p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_crear(BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT)
    IS 'POST /grados. Gate CREAR con el alcance del periodo academico; delega en fn_grado_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(
    p_pk BIGINT,
    p_fk_nivel BIGINT DEFAULT NULL,
    p_nombre VARCHAR DEFAULT NULL,
    p_fk_grado_siguiente BIGINT DEFAULT NULL,
    p_tiene_grado_siguiente BOOLEAN DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_grado_validar_existe(p_pk);
    PERFORM academico_test.fn_grado_validar_activo(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del grado %s en la sede %s', COALESCE(p_nombre, v_nombre),
            (SELECT s.NOMBRE FROM academico_test.TSEDE s WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo))),
        v_est);
    RETURN academico_test.fn_grado_actualizar_interno(p_pk, p_fk_nivel, p_nombre, p_fk_grado_siguiente,
        p_tiene_grado_siguiente, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_actualizar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, BIGINT)
    IS 'PUT /grados/:ID. Gate EDITAR con el alcance del periodo academico; delega en fn_grado_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_grado_validar_existe(p_pk);
    SELECT FK_TPERIODO_ACADEMICO, NOMBRE INTO v_periodo, v_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del grado %s en la sede %s', v_nombre,
            COALESCE((SELECT s.NOMBRE FROM academico_test.TSEDE s
                       WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo)), 'desconocida')),
        v_est);
    RETURN academico_test.fn_grado_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_soft_delete(BIGINT, BIGINT)
    IS 'PUT /grados/:ID/eliminar. Gate ELIMINAR con el alcance del periodo academico; delega en fn_grado_eliminar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_grado_bulk_delete(BIGINT[], BIGINT);

-- Cada id se gatea con su propio alcance dentro de fn_grado_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, NULL);
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_grado_soft_delete(v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_grado_bulk_delete(BIGINT[], BIGINT)
    IS 'PUT /grados/eliminacion-masiva. Un resultado por id; los errores no cortan el lote.';

DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION academico_test.fn_grado_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grado_siguiente VARCHAR, grado_siguiente_name VARCHAR, tiene_grado_siguiente BOOLEAN,
    total_count BIGINT, codigo INT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todas las filas son del mismo periodo academico: el alcance se mira una vez.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT l.id, l.nombre, l.grado, l.teaching_level_id, l.teaching_level_name,
                        l.grado_siguiente, l.grado_siguiente_name, l.tiene_grado_siguiente,
                        l.total_count, l.codigo
      FROM academico_test.fn_grado_listar_interno(
        p_fk_periodo, p_filtro, p_page_index, p_page_size, p_sort_by, p_sort_dir) l;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /grados/query/:FK_PERIODO. Vacio si el usuario no alcanza el periodo academico; delega en fn_grado_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_obtener(
    p_fk_grado BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, grado_siguiente_name VARCHAR,
               tiene_grado_siguiente BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT d.id, d.nombre, d.grado, d.teaching_level_id, d.teaching_level_name,
           d.grado_siguiente, d.grado_siguiente_name, d.tiene_grado_siguiente
      FROM academico_test.fn_grado_obtener_interno(p_fk_grado) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, d.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_grado_obtener(BIGINT, BIGINT)
    IS 'GET /grados/:ID. Vacio si no existe o el usuario no alcanza su periodo academico.';

-- ---------------------------------------------------------------- grupo

-- Sede, jornada y periodo salen del grado activo: el alcance de nivel 3 los necesita.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_crear(
    p_fk_grado BIGINT,
    p_nombre VARCHAR,
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad NUMERIC,
    p_fk_funcionario BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_jornada BIGINT; v_sede BIGINT; v_est BIGINT;
BEGIN
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TLV_JORNADA, pa.FK_TSEDE
      INTO v_periodo, v_jornada, v_sede
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est, v_sede, v_jornada, 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del grupo %s en la sede %s', p_nombre,
            (SELECT s.NOMBRE FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_sede)),
        v_est);
    RETURN academico_test.fn_grupo_crear_interno(p_fk_grado, p_nombre, p_fk_modelo_pedagogico, p_capacidad,
        p_fk_funcionario, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_crear(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT)
    IS 'POST /grados/:ID/grupos. Gate CREAR con sede y jornada del periodo del grado; delega en fn_grupo_crear_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_grupo_actualizar(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_actualizar(
    p_pk BIGINT,
    p_nombre VARCHAR DEFAULT NULL,
    p_fk_modelo_pedagogico BIGINT DEFAULT NULL,
    p_capacidad NUMERIC DEFAULT NULL,
    p_fk_funcionario BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_jornada BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_grupo_validar_existe(p_pk);
    PERFORM academico_test.fn_grupo_validar_activo(p_pk);
    SELECT g.FK_TPERIODO_ACADEMICO, gr.FK_TLV_JORNADA, gr.NOMBRE INTO v_periodo, v_jornada, v_nombre
      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    -- Jornada propia del grupo, no la del periodo.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est, academico_test.fn_periodo_sede(v_periodo), v_jornada, 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del grupo %s en la sede %s', COALESCE(p_nombre, v_nombre),
            (SELECT s.NOMBRE FROM academico_test.TSEDE s WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo))),
        v_est);
    RETURN academico_test.fn_grupo_actualizar_interno(p_pk, p_nombre, p_fk_modelo_pedagogico, p_capacidad,
        p_fk_funcionario, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_actualizar(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT)
    IS 'PUT /grupos/:ID. Gate EDITAR con la sede del periodo y la jornada del grupo; delega en fn_grupo_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_jornada BIGINT; v_nombre VARCHAR(130); v_est BIGINT;
BEGIN
    PERFORM academico_test.fn_grupo_validar_existe(p_pk);
    SELECT g.FK_TPERIODO_ACADEMICO, gr.FK_TLV_JORNADA, gr.NOMBRE INTO v_periodo, v_jornada, v_nombre
      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk;
    v_est := academico_test.fn_periodo_establecimiento(v_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est, academico_test.fn_periodo_sede(v_periodo), v_jornada, 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del grupo %s en la sede %s', v_nombre,
            COALESCE((SELECT s.NOMBRE FROM academico_test.TSEDE s
                       WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo)), 'desconocida')),
        v_est);
    RETURN academico_test.fn_grupo_eliminar_interno(p_pk, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_soft_delete(BIGINT, BIGINT)
    IS 'PUT /grupos/:ID/eliminar. Gate ELIMINAR con la sede del periodo y la jornada del grupo; delega en fn_grupo_eliminar_interno.';

-- Cada id se gatea con su propio alcance dentro de fn_grupo_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_bulk_delete(
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
            PERFORM academico_test.fn_grupo_soft_delete(v_id, p_pk_usuario_solicitante);
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

COMMENT ON FUNCTION academico_test.fn_grupo_bulk_delete(BIGINT[], BIGINT)
    IS 'POST /grupos/bulk-delete. Un resultado por id; los errores no cortan el lote.';

DROP FUNCTION IF EXISTS academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR, director_id BIGINT,
               director_name TEXT, metodologia VARCHAR, metodologia_name VARCHAR, cupo NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Todos los grupos son del mismo grado y por tanto del mismo periodo academico.
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
           (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado)) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT l.id, l.codigo, l.jornada, l.jornada_name, l.director_id, l.director_name,
                        l.metodologia, l.metodologia_name, l.cupo, l.total_count
      FROM academico_test.fn_grupo_listar_interno(
        p_fk_grado, p_filtro, p_page_index, p_page_size, p_sort_by, p_sort_dir) l;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT)
    IS 'POST /grados/:FK_GRADO/grupos/query. Vacio si el usuario no alcanza el periodo academico del grado; delega en fn_grupo_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR,
               director_id BIGINT, director_name TEXT, director_rol_id BIGINT,
               metodologia_id BIGINT, metodologia VARCHAR, metodologia_name VARCHAR,
               cupo NUMERIC, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT d.id, d.codigo, d.jornada, d.jornada_name, d.director_id, d.director_name, d.director_rol_id,
           d.metodologia_id, d.metodologia, d.metodologia_name, d.cupo, d.grado_id
      FROM academico_test.fn_grupo_obtener_interno(p_pk) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, d.academic_period_id);
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_obtener(BIGINT, BIGINT)
    IS 'GET /grupos/:ID. Vacio si no existe o el usuario no alcanza su periodo academico.';

-- ---------------------------------------------------------------- selects del formulario

CREATE OR REPLACE FUNCTION academico_test.fn_nivel_ensenanza_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT PK_NIVEL_ENSENANZA, CODIGO, NOMBRE
      FROM academico_test.TNIVEL_ENSENANZA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_nivel_ensenanza_listar(BIGINT)
    IS 'GET /niveles-ensenanza y /catalogos/niveles-ensenanza. Catalogo de niveles activos, sin alcance.';

-- Candidatos a director: funcionarios activos con un TSEDE_USUARIO activo en la sede.
CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_sede_listar(
    p_fk_sede BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre TEXT, identificacion VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.PK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')) AS nombre,
           u.IDENTIFICACION
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
     WHERE su.FK_TSEDE = p_fk_sede
       AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
       AND f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR u.PRIMER_NOMBRE   ILIKE '%' || p_filtro || '%'
            OR u.PRIMER_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.SEGUNDO_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.IDENTIFICACION  ILIKE '%' || p_filtro || '%')
     ORDER BY nombre;
$$;

COMMENT ON FUNCTION academico_test.fn_funcionario_sede_listar(BIGINT, TEXT, BIGINT)
    IS 'GET /sedes/:ID/funcionarios. Select de director de grupo; sin gate ni alcance.';

-- ---------------------------------------------------------------- configuracion del grado

-- Compone horario y criterio de promocion: cada uno aplica su propio gate y alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_obtener(
    p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_periodo BIGINT; v_entries jsonb; v_prom jsonb; v_req jsonb; c RECORD;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'grupoId', h.grupo_id, 'planItemId', h.plan_item_id,
             'diaId', h.dia_id, 'bloque', h.bloque)), '[]'::jsonb)
      INTO v_entries FROM academico_test.fn_horario_listar(p_fk_grado, NULL, p_pk_usuario_solicitante) h;
    -- fn_criterio_prom_obtener resuelve el override del grado o el default del periodo.
    SELECT * INTO c FROM academico_test.fn_criterio_prom_obtener(v_periodo, p_fk_grado, p_pk_usuario_solicitante) LIMIT 1;
    IF c.id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(COALESCE(a.subject_id, a.area_id)::text), '[]'::jsonb)
          INTO v_req FROM academico_test.fn_criterio_prom_asig_listar(c.id) a;
        v_prom := jsonb_build_object(
            'curriculumNode', c.curriculum_node,
            'maxFailedRecovery', c.max_failed_recovery,
            'absencePercentage', c.absence_percentage,
            'maxLeveledSubjects', c.max_leveled_subjects,
            'applyAverageApproval', (c.apply_average_approval = 'S'),
            'basePercentage', c.base_percentage,
            'minimumSubjectPercentage', c.minimum_subject_percentage,
            'maxFailedForAverage', c.max_failed_for_average,
            'requiredSubjects', v_req
        );
    END IF;
    RETURN jsonb_build_object(
        'schedule', jsonb_build_object('entries', v_entries),
        'promotionCriteria', v_prom
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grade_config_obtener(BIGINT, BIGINT)
    IS 'GET /grados/:ID/configuracion. Horario (fn_horario_listar) + criterio de promocion (fn_criterio_prom_obtener) del grado.';

-- Sin gate propio ni auditoria: fn_horario_guardar y fn_criterio_prom_guardar gatean y declaran cada uno.
CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_guardar(
    p_fk_grado  BIGINT,
    p_schedule  jsonb DEFAULT NULL,
    p_promotion jsonb DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_oblig jsonb;
BEGIN
    IF p_schedule IS NOT NULL AND p_schedule ? 'entries' THEN
        PERFORM academico_test.fn_horario_guardar(p_fk_grado, p_schedule->'entries', p_pk_usuario_solicitante);
    END IF;
    IF p_promotion IS NOT NULL THEN
        SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        -- requiredSubjects llega como array de ids; se remapea a [{asignaturaId}].
        IF p_promotion ? 'requiredSubjects' THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object('asignaturaId', (x)::bigint)), '[]'::jsonb)
              INTO v_oblig
              FROM jsonb_array_elements_text(p_promotion->'requiredSubjects') x
             WHERE NULLIF(TRIM(x),'') IS NOT NULL;
        END IF;
        PERFORM academico_test.fn_criterio_prom_guardar(
            v_periodo, p_fk_grado,
            NULLIF(TRIM(p_promotion->>'curriculumNode'),'')::academico_test.nodo_curricular,
            NULLIF(p_promotion->>'maxFailedRecovery','')::numeric,
            NULL,  -- p_asignatura_obligatoria (no lo maneja el front)
            CASE lower(p_promotion->>'applyAverageApproval')
                 WHEN 'true' THEN 'S' WHEN 'false' THEN 'N' ELSE NULL END::academico_test.bool_sn,
            NULLIF(p_promotion->>'basePercentage','')::numeric,
            NULLIF(p_promotion->>'minimumSubjectPercentage','')::numeric,
            NULLIF(p_promotion->>'maxFailedForAverage','')::numeric,
            NULLIF(p_promotion->>'absencePercentage','')::numeric,
            NULLIF(p_promotion->>'maxLeveledSubjects','')::numeric,
            v_oblig,
            p_pk_usuario_solicitante
        );
    END IF;
    RETURN p_fk_grado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grade_config_guardar(BIGINT, JSONB, JSONB, BIGINT)
    IS 'PUT /grados/:ID/configuracion. Guarda horario (fn_horario_guardar) y criterio de promocion (fn_criterio_prom_guardar) del grado.';

-- --------------------------------------------------------------- reporte
-- Una fila por grado + grupo de todo el periodo (antes V187); un grado sin
-- grupos sale igual (LEFT JOIN).
CREATE OR REPLACE FUNCTION academico_test.fn_grado_grupo_reporte_listar(
    p_fk_periodo BIGINT,
    p_fk_grado   BIGINT[] DEFAULT NULL,
    p_pk_usuario BIGINT   DEFAULT NULL,
    p_page_index INT      DEFAULT 0,
    p_page_size  INT      DEFAULT 10
)
RETURNS TABLE (
    grado_id BIGINT, grado_name VARCHAR, grado_codigo VARCHAR,
    teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    director_id BIGINT, director_name TEXT,
    plan_estudio_name VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    -- Los mismos nucleos que la pantalla (grados del periodo y grupos de cada
    -- grado); LEFT para que un grado sin grupos salga igual.
    SELECT g.id, g.nombre, g.codigo_texto,
           g.teaching_level_id, g.teaching_level_name,
           gr.id, gr.codigo,
           gr.jornada_id, gr.jornada_name,
           gr.director_id, NULLIF(gr.director_name, ''),
           plan.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.fn_grado_listar_interno(p_fk_periodo, NULL, 0, 0) g
 LEFT JOIN LATERAL academico_test.fn_grupo_listar_interno(g.id, NULL, 0, 0) gr ON TRUE
 LEFT JOIN LATERAL (
       SELECT p.NOMBRE
         FROM academico_test.TPLAN p
        WHERE p.FK_TGRADO = g.id AND p.ACTIVE = TRUE
        ORDER BY p.PK_TPLAN
        LIMIT 1
 ) plan ON TRUE
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS TRUE
       AND (p_fk_grado IS NULL OR CARDINALITY(p_fk_grado) = 0 OR g.id = ANY(p_fk_grado))
     ORDER BY g.nombre, gr.codigo
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

COMMENT ON FUNCTION academico_test.fn_grado_grupo_reporte_listar(BIGINT, BIGINT[], BIGINT, INT, INT)
    IS 'POST /grados/reporte. Grados y grupos del periodo con director, jornada y plan; vacio si el usuario no alcanza el periodo.';
