-- fn_subject_periodo_listar solo devolvia FK_TENFASIS (id crudo), nunca el
-- nombre del enfasis/especialidad. El select de "asignaturas obligatorias"
-- del criterio de promocion (front, tab-promotion-criteria.tsx) usa este
-- listado para poblar sus opciones; con nombres de asignatura repetidos
-- ahora validos entre distintos enfasis (ver V143), el front necesita poder
-- mostrar "Matematicas (Enfasis A)" / "Matematicas (Enfasis B)" para que las
-- opciones sean distinguibles.
--
-- Cambia el shape de retorno (agrega `enfasis_nombre`), asi que requiere
-- DROP FUNCTION explicito antes del CREATE OR REPLACE (Postgres no permite
-- cambiar columnas de un RETURNS TABLE con solo REPLACE). Sin cambios de
-- parametros, filtro, orden ni paginado.

DROP FUNCTION IF EXISTS academico_test.fn_subject_periodo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_subject_periodo_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,  -- alcance (global / establecimiento)
    -- Orden: id de columna del front + direccion ('asc'/'desc'), igual que fn_periodo_listar (V37).
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_id BIGINT, area_nombre VARCHAR,
               asignatura_general_id BIGINT, enfasis_id BIGINT, enfasis_nombre VARCHAR,
               color VARCHAR, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'        THEN 's.CODIGO'
        WHEN 'nombreinterno' THEN 's.NOMBRE'
        WHEN 'areanombre'    THEN 'a.NOMBRE'
        WHEN 'ordenreportes' THEN 's.ORDEN_REPORTE'
        ELSE 'a.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, a.PK_TAREA, a.NOMBRE,
               s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS, e.NOMBRE, s.COLOR, s.ORDEN_REPORTE,
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA s
          JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA AND a.ACTIVE = TRUE
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
         WHERE a.FK_TPERIODO_ACADEMICO = $1 AND s.ACTIVE = TRUE
           AND academico_test.fn_periodo_usuario_puede_ver($5, $1)
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%' OR s.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, s.NOMBRE, s.PK_TASIGNATURA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;
