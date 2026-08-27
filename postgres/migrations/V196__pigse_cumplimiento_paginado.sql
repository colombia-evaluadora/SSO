-- =============================================================================
-- V196 — listado paginado del tablero de cumplimiento de PIGSE.
--
-- ADITIVO: no toca fn_pigse_cumplimiento_listar() ni el endpoint
-- /cumplimiento/listar que hoy consume el front. Agrega un wrapper al lado,
-- asi nada se rompe entre esta migracion y el deploy del front, y el endpoint
-- viejo se puede borrar despues, cuando ya nadie lo llame.
--
-- FIRMA
-- Calcada de fn_est_listar_paginado (V53), que es el patron del sistema:
-- filtros primero, despues orden (campo + direccion), despues pagina. Los
-- filtros de estado son ARRAYS y no escalares para poder declararlos TEXT[]
-- en param_types -- igual que BODY.FILTERS.STATUS en /establecimientos/query
-- -- y porque el front ya los modela asi (ComplianceFilters.pei: string[]).
--
-- CONTRATO DE SALIDA
-- El mismo que el resto de los fn_x_listar_paginado y el que espera
-- `unwrapPaginated` en el front: UNA sola fila con
--     rows        jsonb    -- array con las mismas columnas que el _listar
--     total_count bigint   -- filas que matchean el filtro, NO las de la pagina
--     page_count  integer
--     page_index  integer
--     page_size   integer
--
-- ORDEN SIN SQL DINAMICO
-- El campo de orden llega como texto desde el cliente. En vez de concatenarlo
-- a un EXECUTE (inyectable), se resuelve con CASE sobre una lista blanca: un
-- p_sort_campo desconocido cae al orden por defecto en vez de ejecutar nada.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_pigse_cumplimiento_listar_paginado(
    p_search     varchar   DEFAULT NULL,
    p_pei        varchar[] DEFAULT NULL,
    p_pec        varchar[] DEFAULT NULL,
    p_pmi        varchar[] DEFAULT NULL,
    p_sort_campo varchar   DEFAULT NULL,
    p_sort_desc  boolean   DEFAULT false,
    p_page_index integer   DEFAULT 0,
    p_page_size  integer   DEFAULT 10
)
RETURNS TABLE(
    rows        jsonb,
    total_count bigint,
    page_count  integer,
    page_index  integer,
    page_size   integer
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    -- El tamano se acota a [1, 200]: un p_page_size de 0 haria una division
    -- por cero al calcular page_count, y uno enorme convierte el endpoint
    -- paginado en un "traeme todo", que es justo lo que se quiere evitar.
    v_page_size  integer := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index integer := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      varchar := COALESCE(NULLIF(p_sort_campo, ''), 'establishmentName');
    v_desc       boolean := COALESCE(p_sort_desc, false);
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT * FROM academico_test.fn_pigse_cumplimiento_listar()
    ),
    filtrada AS (
        SELECT b.*
          FROM base b
         WHERE (
                 -- Busqueda insensible a mayusculas Y a tildes. Se usa
                 -- translate() y no la extension `unaccent` porque esa NO
                 -- esta instalada en el cluster (solo pgcrypto). Cubre el
                 -- espanol, que es lo que hay en TESTABLECIMIENTO, y replica
                 -- lo que hace el front con normalize("NFD").
                 NULLIF(p_search, '') IS NULL
                 OR translate(lower(b."establishmentName"), 'áéíóúüñ', 'aeiouun')
                    LIKE '%' || translate(lower(p_search), 'áéíóúüñ', 'aeiouun') || '%'
               )
           -- Un array NULL o vacio no filtra. `= ANY` deja la puerta abierta
           -- a multi-seleccion sin tocar la firma.
           AND (COALESCE(array_length(p_pei, 1), 0) = 0 OR b.pei->>'status' = ANY(p_pei))
           AND (COALESCE(array_length(p_pec, 1), 0) = 0 OR b.pec->>'status' = ANY(p_pec))
           AND (COALESCE(array_length(p_pmi, 1), 0) = 0 OR b.pmi->>'status' = ANY(p_pmi))
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
                       -- Desempate estable y orden por defecto. Sin un
                       -- criterio final deterministico, dos EE con el mismo
                       -- progreso pueden intercambiarse entre paginas y el
                       -- usuario ve en la 2 una fila que ya vio en la 1.
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
        -- `- 'rn'` saca la columna auxiliar del row_number: el front espera
        -- exactamente las columnas del _listar, ni una mas.
        COALESCE(
            (SELECT jsonb_agg(to_jsonb(p) - 'rn' ORDER BY p.rn) FROM pagina p),
            '[]'::jsonb
        ),
        (SELECT COUNT(*) FROM filtrada),
        GREATEST(1, CEIL((SELECT COUNT(*) FROM filtrada)::numeric / v_page_size)::integer),
        v_page_index,
        v_page_size;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_pigse_cumplimiento_listar_paginado(
    varchar, varchar[], varchar[], varchar[], varchar, boolean, integer, integer
) IS
'Tablero de cumplimiento paginado. Envuelve fn_pigse_cumplimiento_listar() '
'aplicando busqueda por nombre, filtro por estado de PEI/PEC/PMI, orden y '
'paginacion. Devuelve una fila con {rows, total_count, page_count, page_index, '
'page_size}, igual que fn_est_listar_paginado.';
