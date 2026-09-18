-- fn_asignacion_docente_listar (V46) filtraba los docentes candidatos a
-- Asignaciones Académicas solo por sede + rol (TSEDE_USUARIO.FK_TROL = 14),
-- pero TSEDE_USUARIO.FK_TLV_JORNADA guarda la jornada de ESE permiso
-- puntual (un mismo usuario puede tener un permiso por jornada, ver
-- UK_TSEDE_USUARIO_1 en V22) -- sin compararla contra la jornada del
-- período, el listado mostraba a TODOS los docentes con permiso en la
-- sede, de cualquier jornada, en vez de solo los que tienen permiso en la
-- jornada del período académico que se está armando.
--
-- CREATE OR REPLACE, misma firma: el catálogo de query-service no cambia.
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
