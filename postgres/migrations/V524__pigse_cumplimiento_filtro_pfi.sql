-- ===========================================================================
-- V524 — pigse.fn_cumplimiento_listar_paginado (POST /cumplimiento/query):
-- tablero de "Monitoreo y cumplimiento institucional" paginado en servidor.
-- Filtros: texto (nombre, código DANE o municipio), estado por tipo
-- (PEI/PEC/PMI/PFI; acepta el status de siempre COMPLETO/PENDIENTE/NO_APLICA
-- o el estado derivado PARCIAL/SIN_CARGAR), municipios, etnoeducativo y plazo
-- (VENCIDO = venció sin completar, PRORROGA = con excepción, VIGENTE,
-- SIN_FECHA). Todo filtro nuevo es opcional: un body viejo sigue igual.
-- Depende de: V523 (fn_cumplimiento_listar).
-- ===========================================================================
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_listar_paginado(
    VARCHAR, VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_listar_paginado(
    VARCHAR, VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR, BOOLEAN, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_listar_paginado(
    p_search     VARCHAR   DEFAULT NULL,
    p_pei        VARCHAR[] DEFAULT NULL,
    p_pec        VARCHAR[] DEFAULT NULL,
    p_pmi        VARCHAR[] DEFAULT NULL,
    p_pfi        VARCHAR[] DEFAULT NULL,
    p_municipios BIGINT[]  DEFAULT NULL,
    p_etnias     VARCHAR   DEFAULT NULL,
    p_plazo      VARCHAR[] DEFAULT NULL,
    p_sort_campo VARCHAR   DEFAULT NULL,
    p_sort_desc  BOOLEAN   DEFAULT FALSE,
    p_page_index INTEGER   DEFAULT 0,
    p_page_size  INTEGER   DEFAULT 10
)
RETURNS TABLE(rows JSONB, total_count BIGINT, page_count INTEGER,
              page_index INTEGER, page_size INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    -- [1, 200]: 0 dividiría por cero y un valor enorme es un "traeme todo".
    v_page_size  integer := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index integer := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      varchar := COALESCE(NULLIF(p_sort_campo, ''), 'establishmentName');
    v_desc       boolean := COALESCE(p_sort_desc, false);
    v_search     varchar := translate(lower(NULLIF(trim(p_search), '')), 'áéíóúüñ', 'aeiouun');
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT * FROM pigse.fn_cumplimiento_listar()
    ),
    filtrada AS (
        SELECT b.*
          FROM base b
         WHERE (
                 -- translate() en vez de unaccent: la extensión no está instalada.
                 v_search IS NULL
                 OR translate(lower(b."establishmentName"), 'áéíóúüñ', 'aeiouun') LIKE '%' || v_search || '%'
                 OR lower(COALESCE(b."establishmentCode", '')) LIKE '%' || v_search || '%'
                 OR translate(lower(COALESCE(b.municipio, '')), 'áéíóúüñ', 'aeiouun') LIKE '%' || v_search || '%'
               )
           AND (COALESCE(array_length(p_pei, 1), 0) = 0
                OR b.pei->>'status' = ANY(p_pei) OR b.pei->>'estado' = ANY(p_pei))
           AND (COALESCE(array_length(p_pec, 1), 0) = 0
                OR b.pec->>'status' = ANY(p_pec) OR b.pec->>'estado' = ANY(p_pec))
           AND (COALESCE(array_length(p_pmi, 1), 0) = 0
                OR b.pmi->>'status' = ANY(p_pmi) OR b.pmi->>'estado' = ANY(p_pmi))
           AND (COALESCE(array_length(p_pfi, 1), 0) = 0
                OR b.pfi->>'status' = ANY(p_pfi) OR b.pfi->>'estado' = ANY(p_pfi))
           AND (COALESCE(array_length(p_municipios, 1), 0) = 0 OR b."municipioId" = ANY(p_municipios))
           AND (NULLIF(p_etnias, '') IS NULL
                OR (p_etnias = 'S' AND b.etnoeducativo IS TRUE)
                OR (p_etnias = 'N' AND b.etnoeducativo IS NOT TRUE))
           AND (COALESCE(array_length(p_plazo, 1), 0) = 0
                OR ('VENCIDO' = ANY(p_plazo) AND b.plazo = 'VENCIDO' AND b."globalProgress" < 100)
                OR ('PRORROGA' = ANY(p_plazo) AND b."tieneExcepcion")
                OR ('VIGENTE' = ANY(p_plazo) AND b.plazo = 'VIGENTE')
                OR ('SIN_FECHA' = ANY(p_plazo) AND b.plazo = 'SIN_FECHA'))
    ),
    numerada AS (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   ORDER BY
                       CASE WHEN v_campo = 'globalProgress' AND NOT v_desc THEN f."globalProgress" END ASC,
                       CASE WHEN v_campo = 'globalProgress' AND     v_desc THEN f."globalProgress" END DESC,
                       CASE WHEN v_campo = 'municipio'      AND NOT v_desc THEN f.municipio END ASC,
                       CASE WHEN v_campo = 'municipio'      AND     v_desc THEN f.municipio END DESC,
                       CASE WHEN v_campo = 'lastUploadedAt' AND NOT v_desc THEN f."lastUploadedAt" END ASC NULLS FIRST,
                       CASE WHEN v_campo = 'lastUploadedAt' AND     v_desc THEN f."lastUploadedAt" END DESC NULLS LAST,
                       CASE WHEN v_campo = 'fechaLimite'    AND NOT v_desc THEN f."fechaLimite" END ASC,
                       CASE WHEN v_campo = 'fechaLimite'    AND     v_desc THEN f."fechaLimite" END DESC,
                       CASE WHEN v_campo = 'establishmentName' AND v_desc THEN f."establishmentName" END DESC,
                       -- Desempate estable entre páginas.
                       f."establishmentName" ASC
               ) AS rn
          FROM filtrada f
    ),
    pagina AS (
        SELECT *
          FROM numerada
         WHERE rn >  v_page_index * v_page_size
           AND rn <= (v_page_index + 1) * v_page_size
    )
    SELECT
        COALESCE(
            (SELECT jsonb_agg(to_jsonb(p) - 'rn' ORDER BY p.rn) FROM pagina p),
            '[]'::jsonb
        ),
        (SELECT COUNT(*) FROM filtrada),
        GREATEST(1, CEIL((SELECT COUNT(*) FROM filtrada)::numeric / v_page_size)::integer),
        v_page_index,
        v_page_size;
END;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_listar_paginado(VARCHAR, VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR[], BIGINT[], VARCHAR, VARCHAR[], VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'POST /cumplimiento/query: tablero de Monitoreo paginado. Filtros por estado de cada tipo (status o estado derivado), municipios, etnoeducativo y plazo (VENCIDO/PRORROGA/VIGENTE/SIN_FECHA).';

-- La fila del endpoint existe desde V197/V262: solo cambia el texto y los tipos.
UPDATE public.query
   SET query = 'SELECT * FROM pigse.fn_cumplimiento_listar_paginado(
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.PEI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PEC AS VARCHAR[]),
    CAST(:BODY.FILTERS.PMI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PFI AS VARCHAR[]),
    CAST(:BODY.FILTERS.MUNICIPIOS AS BIGINT[]),
    CAST(:BODY.FILTERS.ETNIAS AS VARCHAR),
    CAST(:BODY.FILTERS.PLAZO AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
       param_types = '{
         "BODY.FILTERS.SEARCH":     "VARCHAR",
         "BODY.FILTERS.PEI":        "TEXT[]",
         "BODY.FILTERS.PEC":        "TEXT[]",
         "BODY.FILTERS.PMI":        "TEXT[]",
         "BODY.FILTERS.PFI":        "TEXT[]",
         "BODY.FILTERS.MUNICIPIOS": "BIGINT[]",
         "BODY.FILTERS.ETNIAS":     "VARCHAR",
         "BODY.FILTERS.PLAZO":      "TEXT[]",
         "BODY.SORTING.ID":         "VARCHAR",
         "BODY.SORTING.DESC":       "BOOLEAN",
         "BODY.PAGEINDEX":          "INTEGER",
         "BODY.PAGESIZE":           "INTEGER"
       }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = query.microservice_id
   AND m.serviceid = 'pigse'
   AND query.path_template = '/cumplimiento/query';
