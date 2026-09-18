-- ===========================================================================
-- V208 - corrige el param_type de BODY.FILTERS.STATUS en la query
--        'audits/query' (microservicio audit-clickhouse): de 'TEXT[]' a
--        'Nullable(String)'.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El SQL de esta query usa STATUS como escalar:
--
--     AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
--          OR status = :BODY.FILTERS.STATUS)
--
--   pero param_types lo declaraba 'TEXT[]' (sintaxis de tipo ARRAY de
--   Postgres). El binder de query-service usa ese tipo para el CAST del
--   parametro y genero `cast(NULL as text[])` -- que ClickHouse no
--   entiende (su sintaxis de array es `Array(String)`, no `text[]`),
--   asi que CUALQUIER llamada a POST /api/audit-ch/audits/query fallaba
--   con 500 (SYNTAX_ERROR, ClickHouse code 62), incluso con body vacio.
--
--   No hay ningun lugar en el SQL donde STATUS se use como array -- es
--   un solo valor de texto (el estado de una sesion: 'active'/'closed').
--   Corregir el tipo a Nullable(String) (igual que el resto de los
--   filtros de texto de esta misma query) alinea la metadata con lo que
--   el SQL realmente hace, sin tocar el SQL ni ningun codigo Java.
-- ===========================================================================

UPDATE public.query
   SET param_types = param_types || '{"BODY.FILTERS.STATUS": "Nullable(String)"}'::jsonb
 WHERE path_template = '/audits/query'
   AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse')
   AND param_types ->> 'BODY.FILTERS.STATUS' = 'TEXT[]';
