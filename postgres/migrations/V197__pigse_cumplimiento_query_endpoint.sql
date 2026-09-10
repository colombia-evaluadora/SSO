-- =============================================================================
-- V197 — registra el endpoint paginado del tablero de PIGSE y le da permisos.
--
-- Va aparte de la funcion (V196) a proposito: la funcion es inocua sin esto,
-- y esto sin la funcion deja un endpoint que revienta. Flyway las corre en
-- orden, asi que V196 siempre va primero.
--
-- TODO ES ADITIVO E IDEMPOTENTE: no toca la fila de /cumplimiento/listar, que
-- sigue sirviendo al front actual hasta que se despliegue el cambio, y
-- correrlo dos veces no duplica nada.
--
-- Los nombres de los binds estan calcados de /establecimientos/query, que es
-- el analogo exacto ya en produccion:
--     BODY.FILTERS.SEARCH   VARCHAR
--     BODY.FILTERS.STATUS   TEXT[]
--     BODY.SORTING.ID       VARCHAR
--     BODY.SORTING.DESC     BOOLEAN
--     BODY.PAGEINDEX        INTEGER
--     BODY.PAGESIZE         INTEGER
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. El endpoint
--
-- Solo `uuid` y `query` son NOT NULL sin default; execution_mode ('SELECT'),
-- http_method ('POST'), param_types ('{}'), public_end/captcha/cacheable
-- (false), cache_ttl_seconds (60) y createddate ya traen el suyo. Se nombran
-- igual los que importan, para no depender de defaults.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid,
    query,
    type,
    microservice_id,
    path_template,
    execution_mode,
    http_method,
    param_types
)
SELECT
    gen_random_uuid()::varchar,
    'SELECT * FROM academico_test.fn_pigse_cumplimiento_listar_paginado(
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.PEI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PEC AS VARCHAR[]),
    CAST(:BODY.FILTERS.PMI AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
    'postgres',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'pigse'),
    '/cumplimiento/query',
    'SELECT',
    'POST',   -- Lectura con body, igual que /establecimientos/query. El
              -- sufijo /query marca que lee, no que muta.
    -- Ningun bind es obligatorio: sin filtros la funcion cae a sus DEFAULT y
    -- devuelve la primera pagina completa.
    '{
       "BODY.FILTERS.SEARCH": "VARCHAR",
       "BODY.FILTERS.PEI":    "TEXT[]",
       "BODY.FILTERS.PEC":    "TEXT[]",
       "BODY.FILTERS.PMI":    "TEXT[]",
       "BODY.SORTING.ID":     "VARCHAR",
       "BODY.SORTING.DESC":   "BOOLEAN",
       "BODY.PAGEINDEX":      "INTEGER",
       "BODY.PAGESIZE":       "INTEGER"
     }'::jsonb
WHERE NOT EXISTS (
    SELECT 1
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE q.path_template = '/cumplimiento/query'
       AND m.serviceid = 'pigse'
);

-- ---------------------------------------------------------------------------
-- 2. Los permisos
--
-- Sin esto el gateway responde 403 y la pantalla queda vacia. Se COPIAN los
-- roles que ya tiene /cumplimiento/listar en vez de listarlos a mano: asi el
-- endpoint nuevo no puede quedar desincronizado del viejo.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, nuevo.id_query
  FROM public.query nuevo
  JOIN public.microservice m
    ON m.id_microservice = nuevo.microservice_id
   AND m.serviceid = 'pigse'
  JOIN public.query viejo
    ON viejo.path_template   = '/cumplimiento/listar'
   AND viejo.microservice_id = nuevo.microservice_id
  JOIN public.role_query rq
    ON rq.query_id = viejo.id_query
 WHERE nuevo.path_template = '/cumplimiento/query'
   AND NOT EXISTS (
       SELECT 1
         FROM public.role_query existente
        WHERE existente.query_id = nuevo.id_query
          AND existente.role_id  = rq.role_id
   );
