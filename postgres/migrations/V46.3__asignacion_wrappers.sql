-- ===========================================================================
-- V46.3 -- Asignacion academica: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V92 y V135. Escritura:
-- existencia (P0002) -> estado (22023) -> gate con el alcance del periodo
-- academico -> fn_audit_declarar -> delegar en V46.2 (que valida el
-- funcionario y los pares). Lectura: vacio si no alcanza el periodo.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V46.1 / V46.2 / V46.3).
-- DEPENDE DE: V29 (gates, alcance), V66 (auditoria), V46.1, V46.2, V43.2.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(
    p_academic_period_id bigint,
    p_fk_funcionario bigint,
    p_subject_ids text[],
    p_pk_usuario_solicitante bigint
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT; v_nombre_periodo TEXT; v_nombre_funcionario TEXT;
BEGIN
    PERFORM academico_test.fn_asignacion_validar_periodo_existe(p_academic_period_id);
    PERFORM academico_test.fn_asignacion_validar_periodo_activo(p_academic_period_id);
    v_est := academico_test.fn_periodo_establecimiento(p_academic_period_id);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'EDITAR');

    SELECT NOMBRE INTO v_nombre_periodo
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;
    SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_nombre_funcionario
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Asignación académica del docente %s para el periodo %s', v_nombre_funcionario, v_nombre_periodo),
        v_est);
    RETURN academico_test.fn_asignacion_guardar_interno(
        p_academic_period_id, p_fk_funcionario, p_subject_ids, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_guardar(BIGINT, BIGINT, TEXT[], BIGINT)
    IS 'POST /asignaciones. Gate EDITAR con el alcance del periodo academico; delega en fn_asignacion_guardar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente(
    p_academic_period_id BIGINT, p_fk_funcionario BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (assignment_id TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF academico_test.fn_periodo_puede_ver(p_pk_usuario, p_academic_period_id) IS NOT TRUE THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_asignacion_docente_interno(p_academic_period_id, p_fk_funcionario);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_docente(BIGINT, BIGINT, BIGINT)
    IS 'GET /asignaciones/:ACADEMIC_PERIOD_ID/docente/:ID. Vacio si el usuario no alcanza el periodo academico; delega en fn_asignacion_docente_interno.';

-- --------------------------------------------------- listados y reporte
-- Docentes candidatos: permiso de docente en la sede Y en la jornada del
-- periodo (antes V264).
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente_listar(p_academic_period_id bigint, p_estado text DEFAULT NULL::text, p_filtro text DEFAULT NULL::text, p_pk_usuario bigint DEFAULT NULL::bigint, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10, p_sort_by text DEFAULT NULL::text, p_sort_dir text DEFAULT NULL::text)
 RETURNS TABLE(funcionario_id bigint, document_number character varying, nombre_completo text, estado text, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'documentnumber' THEN 'document_number'
        WHEN 'status'         THEN 'estado'
        ELSE 'nombre_completo'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT * FROM (
            SELECT DISTINCT f.PK_TFUNCIONARIO AS funcionario_id, u.IDENTIFICACION AS document_number,
                   TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       AS nombre_completo,
                   su.TLV_ESTADO::text AS estado,
                   count(*) OVER()::BIGINT AS total_count
              FROM academico_test.TPERIODO_ACADEMICO pa
              JOIN academico_test.TSEDE_USUARIO su ON su.FK_TSEDE = pa.FK_TSEDE AND su.ACTIVE = TRUE
                                                  AND su.FK_TROL = 14  -- rol Docente
                                                  AND su.FK_TLV_JORNADA = pa.FK_TLV_JORNADA
              JOIN academico_test.TUSUARIO u      ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
              JOIN academico_test.TFUNCIONARIO f  ON f.FK_TUSUARIO = u.PK_TUSUARIO AND f.ACTIVE = TRUE
             WHERE pa.PK_TPERIODO_ACADEMICO = $1
               AND academico_test.fn_periodo_puede_ver($4, $1)
               AND (NULLIF(TRIM($2),'') IS NULL OR su.TLV_ESTADO = $2)
               AND (NULLIF(TRIM($3),'') IS NULL
                    OR u.IDENTIFICACION ILIKE '%%' || $3 || '%%'
                    OR TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%%' || $3 || '%%')
        ) t
         ORDER BY %s %s, funcionario_id
         LIMIT NULLIF($6, 0)
        OFFSET COALESCE($5, 0) * COALESCE(NULLIF($6, 0), 0)
    $q$, v_col, v_dir)
    USING p_academic_period_id, p_estado, p_filtro, p_pk_usuario, p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_docente_listar(BIGINT, TEXT, TEXT, BIGINT, INT, INT, TEXT, TEXT)
    IS 'GET /asignaciones/docentes/:ID y POST /asignaciones/docentes/:PERIODO_ACADEMICO_ID. Docentes con permiso en la sede y jornada del periodo; vacio si el usuario no alcanza el periodo.';

-- Pool de grupo x asignatura del plan (antes V287). bloqueado_preescolar marca
-- lo que asigna solo el director de grupo de preescolar (V43.2).
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_pool(
    p_academic_period_id BIGINT,
    p_filtro             TEXT    DEFAULT NULL,
    p_solo_sin_docente   BOOLEAN DEFAULT FALSE,
    p_pk_usuario         BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    id TEXT, nombre VARCHAR, grado_grupo TEXT, jornada VARCHAR, jornada_name VARCHAR,
    funcionario_id BIGINT, bloqueado_preescolar BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO || ':' || s.PK_TASIGNATURA, s.NOMBRE,
           g.NOMBRE || ' ' || gr.NOMBRE, jor.VALOR, jor.NOMBRE, da.FK_TFUNCIONARIO,
           da.FK_TFUNCIONARIO IS NOT NULL
               AND academico_test.fn_grado_es_preescolar(g.PK_TGRADO)
               AND da.FK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      FROM academico_test.TGRADO g
      JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
      JOIN academico_test.TPLAN p              ON p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap  ON ap.FK_TPLAN = p.PK_TPLAN AND ap.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s        ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TDOCENTE_ASIGNATURA da
             ON da.FK_TGRUPO = gr.PK_TGRUPO AND da.FK_TASIGNATURA = s.PK_TASIGNATURA
            AND da.FK_TPERIODO_ACADEMICO = p_academic_period_id AND da.ACTIVE = TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_academic_period_id AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_academic_period_id)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR s.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR g.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR gr.NOMBRE ILIKE '%' || p_filtro || '%'
            OR jor.VALOR ILIKE '%' || p_filtro || '%')
       -- Se conserva por compatibilidad: TRUE sigue significando "solo
       -- libres". El front ya no lo manda -- filtra "libre vs. de otro
       -- docente" con `funcionario_id` en el cliente.
       AND (NOT COALESCE(p_solo_sin_docente, FALSE) OR da.FK_TFUNCIONARIO IS NULL)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN, BIGINT)
    IS 'GET /asignaciones/pool/:ACADEMIC_PERIOD_ID. Grupo x asignatura del plan del periodo con su docente; vacio si el usuario no alcanza el periodo.';

-- Una fila por asignacion de todo el periodo (antes V190). La pantalla no
-- lista asignaciones (lista docentes y el pool), asi que el nucleo es propio.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_reporte_listar(
    p_fk_periodo     BIGINT,
    p_fk_funcionario BIGINT[] DEFAULT NULL,
    p_fk_grado       BIGINT[] DEFAULT NULL,
    p_fk_asignatura  BIGINT[] DEFAULT NULL,
    p_fk_jornada     BIGINT[] DEFAULT NULL,
    p_estado         TEXT     DEFAULT NULL,
    p_pk_usuario     BIGINT   DEFAULT NULL,
    p_page_index     INT      DEFAULT 0,
    p_page_size      INT      DEFAULT 10
)
RETURNS TABLE (
    docente_id BIGINT, document_number VARCHAR, docente_nombre TEXT, estado TEXT,
    asignatura_id BIGINT, asignatura VARCHAR,
    grado_id BIGINT, grado_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT r.*
      FROM academico_test.fn_asignacion_reporte_listar_interno(
               p_fk_periodo, p_fk_funcionario, p_fk_grado, p_fk_asignatura, p_fk_jornada,
               p_estado, p_page_index, p_page_size) r
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo) IS TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_reporte_listar(BIGINT, BIGINT[], BIGINT[], BIGINT[], BIGINT[], TEXT, BIGINT, INT, INT)
    IS 'POST /asignaciones/reporte. Asignaciones del periodo (docente, grado, grupo, asignatura, jornada); vacio si el usuario no alcanza el periodo. Delega en fn_asignacion_reporte_listar_interno.';
