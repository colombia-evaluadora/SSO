-- ============================================================================
-- V374 — pigse.fn_documentos_listar_todos_paginado gana filtros por tipo
-- (PEI/PEC/PMI) y estado (COMPLETO/PENDIENTE/NO_APLICA), mismo criterio que
-- Monitoreo y Cumplimiento (fn_cumplimiento_listar_paginado): el front tenía
-- un `<input>` de texto libre a secas para "Gestión Documental" mientras el
-- resto de los listados (Funcionarios, Sedes, Monitoreo y Cumplimiento) usan
-- el mismo patrón de filtros avanzados (SearchQueryBar) -- se pareja acá.
-- ============================================================================

-- Distinta cantidad de parametros que la version de V368 (5 vs 7): para
-- Postgres es un overload nuevo, no un reemplazo -- se dropea el viejo
-- explicitamente para no dejar dos versiones vivas.
DROP FUNCTION IF EXISTS pigse.fn_documentos_listar_todos_paginado(VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION pigse.fn_documentos_listar_todos_paginado(
    p_search      VARCHAR DEFAULT NULL,
    p_tipo        VARCHAR DEFAULT NULL,
    p_estado      VARCHAR DEFAULT NULL,
    p_sort_campo  VARCHAR DEFAULT NULL,
    p_sort_desc   BOOLEAN DEFAULT FALSE,
    p_page_index  INTEGER DEFAULT 0,
    p_page_size   INTEGER DEFAULT 10
)
RETURNS TABLE (rows JSONB, total_count BIGINT, page_count INTEGER, page_index INTEGER, page_size INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index INTEGER := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      VARCHAR := COALESCE(NULLIF(p_sort_campo, ''), 'establecimientoNombre');
    v_desc       BOOLEAN := COALESCE(p_sort_desc, FALSE);
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT * FROM pigse.fn_documentos_listar_todos()
    ),
    filtrada AS (
        SELECT b.*
          FROM base b
         WHERE (NULLIF(p_search, '') IS NULL
                OR translate(lower(b."establecimientoNombre"), 'áéíóúüñ', 'aeiouun')
                   LIKE '%' || translate(lower(p_search), 'áéíóúüñ', 'aeiouun') || '%')
           AND (NULLIF(p_tipo, '') IS NULL OR b."type" = p_tipo)
           AND (NULLIF(p_estado, '') IS NULL OR b.status = p_estado)
    ),
    numerada AS (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   ORDER BY
                       CASE WHEN v_campo = 'establecimientoNombre' AND v_desc
                            THEN f."establecimientoNombre" END DESC,
                       f."establecimientoNombre" ASC,
                       f."type" ASC
               ) AS rn
          FROM filtrada f
    ),
    pagina AS (
        SELECT * FROM numerada
         WHERE rn >  v_page_index * v_page_size
           AND rn <= (v_page_index + 1) * v_page_size
    )
    SELECT
        COALESCE((SELECT jsonb_agg(to_jsonb(p) - 'rn' ORDER BY p.rn) FROM pagina p), '[]'::jsonb),
        (SELECT COUNT(*) FROM filtrada),
        GREATEST(1, CEIL((SELECT COUNT(*) FROM filtrada)::numeric / v_page_size)::integer),
        v_page_index,
        v_page_size;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos_paginado(VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'V374: agrega p_tipo (PEI/PEC/PMI) y p_estado (COMPLETO/PENDIENTE/NO_APLICA) -- mismo patron de filtros que fn_cumplimiento_listar_paginado.';

-- Actualiza la query registrada (misma tecnica que V360/V369: UPDATE por
-- uuid, V368 no se edita in-place) para pasar los dos parametros nuevos.
UPDATE public.query
   SET query = $q$SELECT * FROM pigse.fn_documentos_listar_todos_paginado(
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.FILTERS.TIPO AS VARCHAR),
           CAST(:BODY.FILTERS.ESTADO AS VARCHAR),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           CAST(:BODY.PAGEINDEX AS INTEGER),
           CAST(:BODY.PAGESIZE AS INTEGER)
       )$q$,
       param_types = '{"BODY.PAGESIZE":"INTEGER","BODY.PAGEINDEX":"INTEGER","BODY.SORTING.ID":"VARCHAR","BODY.SORTING.DESC":"BOOLEAN","BODY.FILTERS.SEARCH":"VARCHAR","BODY.FILTERS.TIPO":"VARCHAR","BODY.FILTERS.ESTADO":"VARCHAR"}'::jsonb
 WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'pigse')
   AND path_template = '/documentos/todos/query' AND http_method = 'POST';

DO $$
DECLARE
    v_param_types TEXT;
BEGIN
    SELECT param_types::TEXT INTO v_param_types
      FROM public.query
     WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'pigse')
       AND path_template = '/documentos/todos/query' AND http_method = 'POST';

    IF v_param_types IS NULL OR v_param_types NOT ILIKE '%TIPO%' OR v_param_types NOT ILIKE '%ESTADO%' THEN
        RAISE EXCEPTION 'V374 fallo: /documentos/todos/query no quedo con FILTERS.TIPO/FILTERS.ESTADO en param_types';
    END IF;

    RAISE NOTICE 'V374 OK: fn_documentos_listar_todos_paginado y /documentos/todos/query con filtro tipo/estado.';
END $$;
