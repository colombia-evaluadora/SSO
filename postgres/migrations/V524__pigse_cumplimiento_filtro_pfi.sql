-- V521 separó PMI/PFI (excluyentes por ETNIAS, igual que PEI/PEC) y V523
-- arregló que fn_cumplimiento_listar volviera a traer filas, agregando ya la
-- columna "pfi" al resultado. Pero el filtro de estado del tablero
-- ("Monitoreo y cumplimiento institucional") solo tenía p_pei/p_pec/p_pmi:
-- faltaba el cuarto filtro para que el monitor pueda filtrar "¿quién me debe
-- el PFI?" igual que ya puede con PEI/PEC/PMI.
--
-- Agrega p_pfi VARCHAR[] a fn_cumplimiento_listar_paginado (mismo patrón que
-- los otros tres) y actualiza el endpoint /cumplimiento/query para pasar
-- BODY.FILTERS.PFI. Aditivo: el bind nuevo no es obligatorio (sin filtro cae
-- a NULL = "no filtra"), así que un front viejo que no lo mande sigue
-- funcionando igual que antes.
CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_listar_paginado(
    p_search     VARCHAR   DEFAULT NULL,
    p_pei        VARCHAR[] DEFAULT NULL,
    p_pec        VARCHAR[] DEFAULT NULL,
    p_pmi        VARCHAR[] DEFAULT NULL,
    p_pfi        VARCHAR[] DEFAULT NULL,
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
    -- Se acota a [1, 200]: 0 dividiria por cero al calcular page_count y un
    -- valor enorme convierte el paginado en un "traeme todo".
    v_page_size  integer := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index integer := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      varchar := COALESCE(NULLIF(p_sort_campo, ''), 'establishmentName');
    v_desc       boolean := COALESCE(p_sort_desc, false);
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT * FROM pigse.fn_cumplimiento_listar()
    ),
    filtrada AS (
        SELECT b.*
          FROM base b
         WHERE (
                 -- Insensible a mayusculas y a tildes con translate(): la
                 -- extension `unaccent` no esta instalada en el cluster.
                 NULLIF(p_search, '') IS NULL
                 OR translate(lower(b."establishmentName"), 'áéíóúüñ', 'aeiouun')
                    LIKE '%' || translate(lower(p_search), 'áéíóúüñ', 'aeiouun') || '%'
               )
           -- Un array NULL o vacio no filtra.
           AND (COALESCE(array_length(p_pei, 1), 0) = 0 OR b.pei->>'status' = ANY(p_pei))
           AND (COALESCE(array_length(p_pec, 1), 0) = 0 OR b.pec->>'status' = ANY(p_pec))
           AND (COALESCE(array_length(p_pmi, 1), 0) = 0 OR b.pmi->>'status' = ANY(p_pmi))
           AND (COALESCE(array_length(p_pfi, 1), 0) = 0 OR b.pfi->>'status' = ANY(p_pfi))
    ),
    numerada AS (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   ORDER BY
                       CASE WHEN v_campo = 'globalProgress'    AND NOT v_desc
                            THEN f."globalProgress" END ASC,
                       CASE WHEN v_campo = 'globalProgress'    AND     v_desc
                            THEN f."globalProgress" END DESC,
                       CASE WHEN v_campo = 'establishmentName' AND     v_desc
                            THEN f."establishmentName" END DESC,
                       -- Desempate estable: sin el, dos EE con el mismo
                       -- progreso se intercambian entre paginas.
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

COMMENT ON FUNCTION pigse.fn_cumplimiento_listar_paginado(VARCHAR, VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR[], VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'V524: agrega p_pfi -- mismo patron de filtro que p_pei/p_pec/p_pmi.';

-- El endpoint /cumplimiento/query (V197/V262) pasa a mandar BODY.FILTERS.PFI.
-- UPDATE en vez de INSERT WHERE NOT EXISTS: la fila ya existe desde V262 (que
-- repunto todos los queries de pigse a este esquema), solo cambia el texto
-- del query y sus param_types.
UPDATE public.query
   SET query = 'SELECT * FROM pigse.fn_cumplimiento_listar_paginado(
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.PEI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PEC AS VARCHAR[]),
    CAST(:BODY.FILTERS.PMI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PFI AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
       param_types = '{
         "BODY.FILTERS.SEARCH": "VARCHAR",
         "BODY.FILTERS.PEI":    "TEXT[]",
         "BODY.FILTERS.PEC":    "TEXT[]",
         "BODY.FILTERS.PMI":    "TEXT[]",
         "BODY.FILTERS.PFI":    "TEXT[]",
         "BODY.SORTING.ID":     "VARCHAR",
         "BODY.SORTING.DESC":   "BOOLEAN",
         "BODY.PAGEINDEX":      "INTEGER",
         "BODY.PAGESIZE":       "INTEGER"
       }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = query.microservice_id
   AND m.serviceid = 'pigse'
   AND query.path_template = '/cumplimiento/query';
