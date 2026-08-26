-- Reporte "Asignación académica": `fn_asignacion_docente_listar` (V83, fix
-- de estado en V126) lista DOCENTES de un periodo (una fila por docente, con
-- total_count para paginar), no sus asignaciones puntuales -- no trae
-- asignatura/grado/grupo/jornada. El reporte pedido es uno por asignación
-- (docente + grado + grupo + asignatura + jornada), sin paginar, con filtros
-- por docente/grado/asignatura/jornada/estado.
--
-- Mismo fix que V126 para el estado del docente: TSEDE_USUARIO.TLV_ESTADO en
-- LA SEDE del periodo, no TUSUARIO.ESTADO (cuenta global) -- un docente puede
-- estar activo globalmente pero con otro estado en esta sede puntual.
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
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_funcionario IS NULL OR CARDINALITY(p_fk_funcionario) = 0 OR f.PK_TFUNCIONARIO = ANY(p_fk_funcionario))
       AND (p_fk_grado       IS NULL OR CARDINALITY(p_fk_grado)       = 0 OR g.PK_TGRADO       = ANY(p_fk_grado))
       AND (p_fk_asignatura  IS NULL OR CARDINALITY(p_fk_asignatura)  = 0 OR s.PK_TASIGNATURA  = ANY(p_fk_asignatura))
       AND (p_fk_jornada     IS NULL OR CARDINALITY(p_fk_jornada)     = 0 OR jor.PK_LISTA_VALOR = ANY(p_fk_jornada))
       AND (NULLIF(TRIM(p_estado), '') IS NULL OR su.TLV_ESTADO = p_estado)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE, u.PRIMER_APELLIDO
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;