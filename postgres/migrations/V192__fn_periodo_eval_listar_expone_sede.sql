-- RN-09 (reporte de periodos de evaluacion): el archivo exportado debe incluir
-- como minimo codigo, nombre, abreviacion, fecha inicio, fecha fin, peso
-- porcentual, estado Y SEDE asociada. fn_periodo_eval_listar (V38) nunca
-- devolvio sede -- solo academic_period_id -- asi que el reporte (V124, que
-- reusa esta misma funcion) salia sin ese campo.
--
-- Fix: agrega sede_id/sede_name al final de RETURNS TABLE (aditivo, no rompe
-- al listado del front -- consume por nombre de columna, no posicional) via
-- un JOIN hasta TPERIODO_ACADEMICO -> TSEDE, mismo patron que ya usa
-- fn_periodo_listar (V37) para resolver su propia sede.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_eval_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR, estado_name VARCHAR,
    academic_period_id BIGINT, sede_id BIGINT, sede_name VARCHAR, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'      THEN 'pe.CODIGO'
        WHEN 'nombre'      THEN 'pe.NOMBRE'
        WHEN 'abreviacion' THEN 'pe.ABREVIACION'
        WHEN 'startdate'   THEN 'pe.FECHA_INICIO'
        WHEN 'enddate'     THEN 'pe.FECHA_FIN'
        WHEN 'peso'        THEN 'pe.PORCENTAJE'
        WHEN 'estado'      THEN 'est.VALOR'
        ELSE 'pe.FECHA_INICIO'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT pe.PK_TPERIODO_EVALUACION, pe.CODIGO, pe.NOMBRE, pe.ABREVIACION,
               pe.FECHA_INICIO, pe.FECHA_FIN, pe.PORCENTAJE, pe.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
               pe.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, s.NOMBRE,
               count(*) OVER()::BIGINT
          FROM academico_test.TPERIODO_EVALUACION pe
          JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE pe.FK_TPERIODO_ACADEMICO = $1 AND pe.ACTIVE = TRUE
           AND ($2 IS NULL OR pe.NOMBRE ILIKE '%%' || $2 || '%%' OR pe.CODIGO ILIKE '%%' || $2 || '%%')
           AND academico_test.fn_periodo_usuario_puede_ver($5, pe.FK_TPERIODO_ACADEMICO)
         ORDER BY %s %s, pe.PK_TPERIODO_EVALUACION DESC
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;

-- No hace falta tocar la fila `public.query` del reporte ni la del listado:
-- ambas llaman `SELECT * FROM fn_periodo_eval_listar(...)`, y `SELECT *`
-- recoge las columnas nuevas automaticamente -- son OUT params agregados al
-- final de RETURNS TABLE, no un parametro de entrada nuevo. Falta sí
-- actualizar `reporting-service/application.yml` (columna "sede" en la
-- seccion `periodos-evaluacion`), fuera del alcance de una migracion SQL.
