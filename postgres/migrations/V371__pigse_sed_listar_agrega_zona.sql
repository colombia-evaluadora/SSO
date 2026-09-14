-- ============================================================================
-- V371 — pigse.fn_sed_listar (V370) no traia FK_TLV_ZONA/zona_nombre; el
-- front de Sedes (campuses/columns-campuses.tsx, copiado de CEVAL) SI
-- muestra la columna Zona en la tabla, no solo en el detalle. Se agrega sin
-- tocar la firma (misma CREATE OR REPLACE, V370 no se edita in-place).
-- ============================================================================

CREATE OR REPLACE FUNCTION pigse.fn_sed_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search                 VARCHAR  DEFAULT NULL,
    p_fk_establecimiento     BIGINT   DEFAULT NULL,
    p_sort_campo             VARCHAR  DEFAULT NULL,
    p_sort_desc              BOOLEAN  DEFAULT FALSE,
    p_page_index             INT      DEFAULT 0,
    p_page_size              INT      DEFAULT 10
)
RETURNS TABLE (rows JSONB, total_count BIGINT, page_count BIGINT, page_index INT, page_size INT)
LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_page_size  INT := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    PERFORM pigse.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER');

    SELECT COUNT(*) INTO v_total
      FROM pigse.TSEDE s
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%' OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_fk_establecimiento IS NULL OR s.FK_TESTABLECIMIENTO = p_fk_establecimiento);

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT s.PK_TSEDE AS pk_sede, s.CODIGO AS codigo, s.NOMBRE AS nombre,
               s.CONSECUTIVO AS consecutivo, s.FK_TLV_ZONA AS fk_zona, zv.NOMBRE AS zona_nombre,
               s.FK_TESTABLECIMIENTO AS fk_establecimiento,
               e.NOMBRE AS establecimiento_nombre, s.DIRECCION AS direccion, s.TELEFONO AS telefono,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'nombre' AND NOT p_sort_desc THEN s.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'nombre' AND     p_sort_desc THEN s.NOMBRE END DESC,
                     s.NOMBRE ASC, s.PK_TSEDE ASC
               ) AS orden_fila
          FROM pigse.TSEDE s
          JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
          JOIN pigse.TLISTA_VALOR zv ON zv.PK_LISTA_VALOR = s.FK_TLV_ZONA
         WHERE s.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR s.NOMBRE ILIKE '%' || p_search || '%' OR s.CODIGO ILIKE '%' || p_search || '%')
           AND (p_fk_establecimiento IS NULL OR s.FK_TESTABLECIMIENTO = p_fk_establecimiento)
         ORDER BY orden_fila
         LIMIT v_page_size OFFSET v_page_index * v_page_size
      ) t;

    RETURN QUERY
    SELECT v_rows, v_total,
           CASE WHEN v_total = 0 THEN 0::BIGINT ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index, v_page_size;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_listar(BIGINT, VARCHAR, BIGINT, VARCHAR, BOOLEAN, INT, INT) IS
    'V371: agrega fk_zona/zona_nombre a la fila (V370 no los traia). Resto sin cambios.';

DO $$
BEGIN
    RAISE NOTICE 'V371 OK: pigse.fn_sed_listar ahora incluye fk_zona/zona_nombre.';
END $$;
