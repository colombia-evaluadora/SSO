-- ===========================================================================
-- V46.2 -- Asignacion academica: nucleos _interno
-- ===========================================================================
-- QUE HACE: guardar la asignacion de un docente en un periodo y leerla, sin
-- permisos. Validan con V46.1 antes de escribir; el gate, el alcance y la
-- auditoria van en V46.3.
-- POR QUE AQUI: capa 2 del modulo (V46.1 / V46.2 / V46.3).
-- DEPENDE DE: V22 (TDOCENTE_ASIGNATURA), V46.1.
-- ===========================================================================

SET search_path TO academico_test, public;

-- p_subject_ids reemplaza toda la asignacion del docente en el periodo.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar_interno(
    p_fk_periodo     BIGINT,
    p_fk_funcionario BIGINT,
    p_subject_ids    TEXT[],
    p_audit          VARCHAR
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_count INT := 0;
    v_pair  TEXT;
    v_grupo BIGINT;
    v_asig  BIGINT;
BEGIN
    PERFORM academico_test.fn_asignacion_validar_funcionario(p_fk_funcionario);

    PERFORM pg_advisory_xact_lock(hashtext('docasig:' || p_fk_periodo::text || ':' || p_fk_funcionario::text));

    UPDATE academico_test.TDOCENTE_ASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TFUNCIONARIO = p_fk_funcionario AND FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE;

    IF p_subject_ids IS NULL THEN
        RETURN 0;
    END IF;

    FOREACH v_pair IN ARRAY p_subject_ids LOOP
        PERFORM academico_test.fn_asignacion_validar_formato(v_pair);
        v_grupo := split_part(v_pair, ':', 1)::BIGINT;
        v_asig  := split_part(v_pair, ':', 2)::BIGINT;
        PERFORM academico_test.fn_asignacion_validar_par(p_fk_periodo, p_fk_funcionario, v_grupo, v_asig);

        INSERT INTO academico_test.TDOCENTE_ASIGNATURA
            (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
        VALUES (v_grupo, p_fk_funcionario, v_asig, p_fk_periodo, p_audit);
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_guardar_interno(BIGINT, BIGINT, TEXT[], VARCHAR)
    IS 'INTERNO: valida y reemplaza las asignaturas (pares grupoId:asignaturaId) de un docente en un periodo academico. Devuelve las insertadas. Lo usa fn_asignacion_guardar.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente_interno(
    p_fk_periodo BIGINT, p_fk_funcionario BIGINT
)
RETURNS TABLE (assignment_id TEXT)
LANGUAGE sql STABLE AS $$
    SELECT da.FK_TGRUPO || ':' || da.FK_TASIGNATURA
      FROM academico_test.TDOCENTE_ASIGNATURA da
     WHERE da.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND da.FK_TFUNCIONARIO = p_fk_funcionario AND da.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_docente_interno(BIGINT, BIGINT)
    IS 'INTERNO: pares grupoId:asignaturaId activos de un docente en un periodo academico, sin alcance. Lo usa fn_asignacion_docente.';

-- ------------------------------------------------ reporte (antes V190)
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_reporte_listar_interno(
    p_fk_periodo     BIGINT,
    p_fk_funcionario BIGINT[] DEFAULT NULL,
    p_fk_grado       BIGINT[] DEFAULT NULL,
    p_fk_asignatura  BIGINT[] DEFAULT NULL,
    p_fk_jornada     BIGINT[] DEFAULT NULL,
    p_estado         TEXT     DEFAULT NULL,
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
    SELECT f.PK_TFUNCIONARIO, u.IDENTIFICACION,
           TRIM(regexp_replace(
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           su.TLV_ESTADO::text,
           s.PK_TASIGNATURA, s.NOMBRE,
           g.PK_TGRADO, g.NOMBRE,
           gr.PK_TGRUPO, gr.NOMBRE,
           jor.PK_LISTA_VALOR, jor.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = da.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = da.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TLISTA_VALOR jor       ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      JOIN academico_test.TASIGNATURA s          ON s.PK_TASIGNATURA = da.FK_TASIGNATURA
      JOIN academico_test.TFUNCIONARIO f         ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO u             ON u.PK_TUSUARIO = f.FK_TUSUARIO
 LEFT JOIN academico_test.TSEDE_USUARIO su        ON su.FK_TUSUARIO = u.PK_TUSUARIO
                                                  AND su.FK_TSEDE = pa.FK_TSEDE
                                                  AND su.FK_TROL = 14 AND su.ACTIVE = TRUE
     WHERE da.FK_TPERIODO_ACADEMICO = p_fk_periodo AND da.ACTIVE = TRUE
       AND (p_fk_funcionario IS NULL OR CARDINALITY(p_fk_funcionario) = 0 OR f.PK_TFUNCIONARIO = ANY(p_fk_funcionario))
       AND (p_fk_grado       IS NULL OR CARDINALITY(p_fk_grado)       = 0 OR g.PK_TGRADO       = ANY(p_fk_grado))
       AND (p_fk_asignatura  IS NULL OR CARDINALITY(p_fk_asignatura)  = 0 OR s.PK_TASIGNATURA  = ANY(p_fk_asignatura))
       AND (p_fk_jornada     IS NULL OR CARDINALITY(p_fk_jornada)     = 0 OR jor.PK_LISTA_VALOR = ANY(p_fk_jornada))
       AND (NULLIF(TRIM(p_estado), '') IS NULL OR su.TLV_ESTADO = p_estado)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE, u.PRIMER_APELLIDO
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_reporte_listar_interno(BIGINT, BIGINT[], BIGINT[], BIGINT[], BIGINT[], TEXT, INT, INT)
    IS 'INTERNO: asignaciones activas de un periodo con filtros, sin alcance. Lo usa fn_asignacion_reporte_listar.';
